freeStyleJob('backup_rocketchat.dsl') {

	description '''
		Резервное копирование базы данных Rocket.Chat на S3-storage
		Зависимости Jenkins: sshPlugin
		Зависимости Shell: restic, fuse
		Зависимости Infrastructure: '''.stripIndent().trim()

	triggers {
		cron('@midnight')
	}

	logRotator {
		numToKeep(7)
	}

	wrappers {
		preBuildCleanup()
		credentialsBinding {
			usernamePassword('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 's3storage')
			usernamePassword('RESTIC_USER', 'RESTIC_PASSWORD', 'restic')
		}
		buildTimeoutWrapper {
			strategy {
				noActivityTimeOutStrategy {
					timeoutSecondsString('1800')
				}
			}
			operationList {
				failOperation()
			}
			timeoutEnvVar('BACKUP_STATUS')
		}
	}

	publishers {
		mailer {
			recipients('adm@example.com')
			notifyEveryUnstableBuild(true)
			sendToIndividuals(false)
		}
	}

	environmentVariables (
		temp_storage: '/mnt/storage/backup',
		s3_storage: 's3.example.com',
		site_name: 'rocketchat.example.com',
		limit_save: '28',
		backup_lock_time_limit: '3600',
		timezone: 'Europe/Moscow',
		backup_targets: '$temp_storage/rocketdb'
	)

	steps {
		sshBuilder {
			siteName ('root@rocket-app01a.infra.example.com:22')
			command (
			'''
			set -xe

			echo
			echo "Rocketchat DB dumping..."
			echo
			mkdir -p $temp_storage
			cd $temp_storage
			rm -rf rocketdb || true
			mongodump -o rocketdb
			'''.stripIndent().trim()
			)
			execEachLine(false)
		}

		sshBuilder {
			siteName ('root@rocket-app01a.infra.example.com:22')
			command (
			'''
			set -xe

			if [[ -z $(restic version) ]]
			then
			  yum install yum-plugin-copr -y && yum copr enable copart/restic -y && yum install restic fuse -y
			fi

			export TZ=$timezone

			echo
			echo "Check if backup database is ready"
			echo
			while \
			  lock=$(restic --repo s3:https://${s3_storage}:9000/main check 2>&1 |
			  grep 'lock was created at' |
			  grep -Eo '[0-9]{4}-([0-9]{2}-?){2} ([0-9]{2}:?){3}')
			do
			  lock_timestamp=$(date -d "$lock" +%s)
			  lock_offset=$(($(date +%s) - $lock_timestamp))
			  echo $lock_offset
			  if [[ $lock_offset -ge $backup_lock_time_limit ]];then
			    restic --repo s3:https://${s3_storage}:9000/main unlock
			    break
			  fi
			  sleep 5
			  echo "Repo locked at $lock. unlock waiting..."
			done

			echo
			echo "Backup storing to S3"
			echo
			restic --repo s3:https://${s3_storage}:9000/main backup $(echo $backup_targets) --tag $site_name
			rm -rf $temp_storage || true
			'''.stripIndent().trim()
			)
			execEachLine(false)
		}

		shell (
		'''
		echo "s3_storage=$s3_storage" > backup_restic_prune_old
		echo "tag=$site_name" >> backup_restic_prune_old
		echo "limit_save=$limit_save" >> backup_restic_prune_old
		'''.stripIndent().trim()
		)
	}

	publishers {
		downstreamParameterized {
			trigger('backup_restic_prune_old.dsl') {
				condition('SUCCESS')
				parameters {
					propertiesFile('backup_restic_prune_old', failTriggerOnMissing = true)
				}
			}
		}
	}
}
