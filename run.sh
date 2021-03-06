#!/bin/bash
cat /etc/mysql/conf.d/mysql_server.cnf

DATADIR=/data
set -- mysqld "$@"

if [ -z $HOSTNAME ]; then
  HOSTNAME=$DOCKERCLOUD_CONTAINER_HOSTNAME
fi

LIMIT=$(echo $HOSTNAME | sed 's/[^0-9]*//g')

MASTER=0
if [ "${HOSTNAME:(-2)}" = '-1' ]; then
  echo "[MASTER]"
  MASTER=1
fi

CLUSTER_ADDR="gcomm://$HOSTNAME"
NAME_FINDER="${HOSTNAME:0:(-2)}"

for (( c=1; c<=$LIMIT; c++ ))
do
  if [ $c -ne $LIMIT ]; then
    CLUSTER_ADDR="$CLUSTER_ADDR,${NAME_FINDER}-$c"
  fi
done

if [ ! -d "$DATADIR/mysql" ]; then
    if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
      echo >&2 'error: database is uninitialized and password option is not specified '
      echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
      exit 1
    fi

    mkdir -p "$DATADIR"

    echo 'Initializing database'
    mysql_install_db --datadir="$DATADIR" --rpm
    echo 'Database initialized'

    "$@" --skip-networking --datadir="$DATADIR" &
    pid="$!"

    mysql=( mysql --protocol=socket -uroot )

    for i in {30..0}; do
      if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
        break
      fi
      echo 'MySQL init process in progress...'
      sleep 1
    done
    if [ "$i" = 0 ]; then
      echo >&2 'MySQL init process failed.'
      exit 1
    fi

    if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
      # sed is for https://bugs.mysql.com/bug.php?id=20545
      mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
    fi

    if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
      MYSQL_ROOT_PASSWORD="$(pwgen -1 32)"
      echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
    fi

    "${mysql[@]}" <<-EOSQL
      -- What's done in this file shouldn't be replicated
      --  or products like mysql-fabric won't work
      SET @@SESSION.SQL_LOG_BIN=0;
      DELETE FROM mysql.user ;
      CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
      GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
      DROP DATABASE IF EXISTS test ;
      FLUSH PRIVILEGES ;
EOSQL

    if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
      mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
    fi

    if [ "$MYSQL_DATABASE" ]; then
      echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
      mysql+=( "$MYSQL_DATABASE" )
    fi

    if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
      echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" | "${mysql[@]}"

      if [ "$MYSQL_DATABASE" ]; then
        echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" | "${mysql[@]}"
      fi

      echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
    fi

    if ! kill -s TERM "$pid" || ! wait "$pid"; then
      echo >&2 'MySQL init process failed.'
      exit 1
    fi

    echo
    echo 'MySQL init process done. Ready for start up.'
    echo
fi

if [ "$MASTER" = 1 ]; then
  if [ -f "$DATADIR/clustered" ]; then
    mysqld --datadir="$DATADIR" --wsrep_node_address=$HOSTNAME --wsrep_cluster_address="gcomm://$NAME_FINDER-2"
  else
    touch "$DATADIR/clustered"
    mysqld --datadir="$DATADIR" --wsrep_node_address=$HOSTNAME --wsrep_cluster_address=$CLUSTER_ADDR --wsrep-new-cluster
  fi
else
  mysqld --datadir="$DATADIR" --wsrep_node_address=$HOSTNAME --wsrep_cluster_address=$CLUSTER_ADDR
fi
