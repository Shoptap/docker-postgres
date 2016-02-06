#!/bin/bash
set -e

build_hba() {
	cp /opt/baseconfig/pg_hba.conf "$PGDATA/pg_hba.conf"
	
	export IFS=","
	for x in $POSTGRES_REPLICATION_ACL; do 
		echo "host    replication     rep     $x   md5" >> "$PGDATA/pg_hba.conf"
	done
	
	echo "" >> "$PGDATA/pg_hba.conf"
	echo "host all all 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"
}

slave_action() {
	if [ "$POSTGRES_STARTUP_SLAVE" = 'true' ]; then
		echo "Starting up in slave mode..."
		echo "Sleeping 5 seconds to make sure network is up."
		sleep 5
		if [ "$POSTGRES_STARTUP_SLAVE_SYNC" = 'true' ]; then
			echo "Re-syncing full database from master..."
			rm -r $PGDATA/* # This is scary
			PGPASSWORD=$POSTGRES_REPLICATION_PASSWORD pg_basebackup -h $POSTGRES_MASTER_IP -p $POSTGRES_MASTER_PORT -P -U rep -D $PGDATA --xlog-method=stream

			# Restore config files
			build_hba
			cp /opt/baseconfig/postgresql.conf "$PGDATA/postgresql.conf"
		fi

        if [ -f "/tmp/postgresql.trigger"]; then
            rm /tmp/postgresql.trigger
        fi

		cp /opt/baseconfig/recovery.conf "$PGDATA/recovery.conf"
		echo "primary_conninfo = 'host=$POSTGRES_MASTER_IP port=$POSTGRES_MASTER_PORT user=rep password=$POSTGRES_REPLICATION_PASSWORD'" >> "$PGDATA/recovery.conf"
	fi
}

if [ "$1" = 'postgres' ]; then
	mkdir -p "$PGDATA"
	chmod 700 "$PGDATA"
	chown -R postgres "$PGDATA"

	chmod g+s /run/postgresql
	chown -R postgres /run/postgresql

	# look specifically for PG_VERSION, as it is expected in the DB dir
	if [ ! -s "$PGDATA/PG_VERSION" ]; then
		gosu postgres initdb

		# check password first so we can output the warning before postgres
		# messes it up
		if [ "$POSTGRES_PASSWORD" ]; then
			pass="PASSWORD '$POSTGRES_PASSWORD'"
			authMethod=md5
		else
			# The - option suppresses leading tabs but *not* spaces. :)
			cat >&2 <<-'EOWARN'
				****************************************************
				WARNING: No password has been set for the database.
				         This will allow anyone with access to the
				         Postgres port to access your database. In
				         Docker's default configuration, this is
				         effectively any other container on the same
				         system.

				         Use "-e POSTGRES_PASSWORD=password" to set
				         it in "docker run".
				****************************************************
			EOWARN

			pass=
			authMethod=trust
		fi

		build_hba

		# internal start of server in order to allow set-up using psql-client		
		# does not listen on TCP/IP and waits until start finishes
		gosu postgres pg_ctl -D "$PGDATA" \
			-o "-c listen_addresses=''" \
			-w start

		: ${POSTGRES_USER:=postgres}
		: ${POSTGRES_DB:=$POSTGRES_USER}
		export POSTGRES_USER POSTGRES_DB

		if [ "$POSTGRES_DB" != 'postgres' ]; then
			psql --username postgres <<-EOSQL
				CREATE DATABASE "$POSTGRES_DB" ;
			EOSQL
			echo
		fi

		if [ "$POSTGRES_USER" = 'postgres' ]; then
			op='ALTER'
		else
			op='CREATE'
		fi

		psql --username postgres <<-EOSQL
			$op USER "$POSTGRES_USER" WITH SUPERUSER $pass ;
			CREATE USER rep REPLICATION LOGIN CONNECTION LIMIT 5 ENCRYPTED PASSWORD '$POSTGRES_REPLICATION_PASSWORD';
			ALTER USER rep CONNECTION LIMIT 5;
		EOSQL
		echo

		echo
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh)  echo "$0: running $f"; . "$f" ;;
				*.sql) 
					echo "$0: running $f"; 
					psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" < "$f"
					echo 
					;;
				*)     echo "$0: ignoring $f" ;;
			esac
			echo
		done

		gosu postgres pg_ctl -D "$PGDATA" -m fast -w stop
		
		cp /opt/baseconfig/postgresql.conf "$PGDATA/postgresql.conf"

		echo
		echo 'PostgreSQL init process complete; ready for start up.'
		echo
	else
		build_hba
		cp /opt/baseconfig/postgresql.conf "$PGDATA/postgresql.conf"
	fi

	slave_action
	chown -R postgres "$PGDATA"
	exec gosu postgres bash -c "$@ $POSTGRES_EXTRAOPTIONS"
else
	exec "$@"
fi



