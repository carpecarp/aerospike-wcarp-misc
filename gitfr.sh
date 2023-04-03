#!/bin/bash
# A mash up of git and make commands to build and run
# c client tests from the latest from upstream github
# repostitories.
#
# performs a git fetch + rebase
#
# Assumes this is run in ${HOME}/aerospike and that you have
# - aerospike-server
# - aerospike-server-enterprise (optional)
# - aerospike-client-c
# cloned in ${HOME}/aerospike

PORT=33000
AS_SERVER_PPID=0

ETC_DIR=${HOME}/aerospike/etc/$$
mkdir -p ${ETC_DIR}

run_server()
{
    cat <<EOF > ${ETC_DIR}/aerospike.conf

service {
	proto-fd-max 15000
}

logging {
	console {
		context any info
	}
}

network {
	service {
	        address localhost
		port ${PORT}
	}

	heartbeat {
		mode multicast
		multicast-group 239.1.99.222
		port 9918

		# To use unicast-mesh heartbeats, remove the 3 lines above, and see
		# aerospike_mesh.conf for alternative.

		interval 150
		timeout 10
	}

	fabric {
		port 3001
	}

	info {
		port 3003
	}
}

namespace test {
	replication-factor 2
	memory-size 4G

	storage-engine memory

	# enable namespace supervisor in order that c-client tests pass
	# uncomment line below
	nsup-period 5
	allow-ttl-without-nsup true
}
EOF

    local proc=$(uname -p)
    # goose sudo for password synchronously before starting asd in the
    # background, be stubborn about sudo getting a password and not
    # simply timing out.
    false ; while [ $? -ne 0 ] ; do sudo ps -p $$ > /dev/null ; sleep 1 ; done
    sudo ${HOME}/aerospike/aerospike-server/target/Linux-${proc}/bin/asd \
	 --foreground --config-file ${ETC_DIR}/aerospike.conf \
	 1>${ETC_DIR}/aerospike.log 2>&1 &
    AS_SERVER_PPID=$!
    sleep 1
    head -1 ${ETC_DIR}/aerospike.log
}

# increase # of fd's
ulimit -n 15000

# Working ssh agent?
SSH_NOT_OK=1
ps -p ${SSH_AGENT_PID} > /dev/null
if [ $? -eq 0 ] ; then
    ssh-add -l > /dev/null
    if [ $? -eq 0 ] ; then
	ssh-add -l | grep as-gh-key-2 > /dev/null
	if [ $? -eq 0 ] ; then
	    SSH_NOT_OK=0
	fi
    fi
fi

if [ ${SSH_NOT_OK} -eq 1 ] ; then
    eval $(ssh-agent)
    ssh-add ~/.ssh/as-gh-key-2
fi

echo --- aerospike-server ---
AS_REBASE_OK=0
( cd ${HOME}/aerospike/aerospike-server ; git fetch --all ; git rebase )
[ $? -eq 0 ] && AS_REBASE_OK=1
( cd ${HOME}/aerospike/aerospike-server ; git status -v)

echo --- aerospike-server-enterprise ---
ASE_REBASE_OK=0
( cd ${HOME}/aerospike/aerospike-server ; git fetch --all ; git rebase )
[ $? -eq 0 ] && ASE_REBASE_OK=1
( cd ${HOME}/aerospike/aerospike-server-enterprise ; git status -v)

echo --- aerospike-client-c ---
ASC_REBASE_OK=0
( cd ${HOME}/aerospike/aerospike-client-c ; git fetch --all ; git rebase )
[ $? -eq 0 ] && ASC_REBASE_OK=1
( cd ${HOME}/aerospike/aerospike-client-c ; git status -v)

AS_BUILD_OK=0
if [ ${AS_REBASE_OK} -eq 1 ] && [ ${ASE_REBASE_OK} -eq 1 ] ; then
    # apply the big hammer
    INCLUDE_EEREPO=
    echo --- building enterprise server ---
    ( cd ${HOME}/aerospike/aerospike-server ;
      git submodule deinit --all --force ;
      git submodule update --init --recursive )
    if [ -d ${EEREPO} ] ; then
	INCLUDE_EEREPO=+ee
	( cd ${EEREPO} ;
	  git submodule deinit --all --force ;
	  git submodule update --init --recursive )
    fi
    ( cd ${HOME}/aerospike/aerospike-server ;
      make cleanall ;
      make -j4 ${INCLUDE_EEREPO} VERBOSE=true )
    [ $? -eq 0 ] && AS_BUILD_OK=1
else
    echo !!! ERROR: one or more server rebase failed, skip building server, stash your changes !!!
fi

ASC_BUILD_OK=0
if [ ${AS_REBASE_OK} -eq 1 ] && [ ${ASE_REBASE_OK} -eq 1 ] && [ ${ASC_REBASE_OK} -eq 1 ] ; then
    echo --- building c client ---
    ( cd ${HOME}/aerospike/aerospike-client-c ;
      git submodule deinit --all --force ;
      git submodule update --init --recursive ;
      make clean ; 
      make VERBOSE=true modules                     \
	&& make VERBOSE=true EVENT_LIB=libuv build  \
	&& make VERBOSE=true prepare
    )
    [ $? -eq 0 ] && ASC_BUILD_OK=1
fi

if [ ${ASC_BUILD_OK} -eq 1 ] ; then
    echo --- Starting Aerospike server ---
    run_server
    sleep 10
fi

if [ ${AS_SERVER_PPID} -ne 0 ] ; then
    echo --- building and running c client tests ---
    ( cd ${HOME}/aerospike/aerospike-client-c ;
      make EVENT_LIB=libuv AS_PORT=${PORT} test
    )
fi

echo --- clean up ---

# AS_SERVER_PPID is pid of sudo, the child (asd process) should be killed
if [ ${AS_SERVER_PPID} -ne 0 ] ; then
    pid=$(ps --no-headers -o pid --ppid ${AS_SERVER_PPID} )
    [ ${pid} != '' ] && sudo kill -15 ${pid}
    sleep 1
fi

if [ -f ${ETC_DIR}/aerospike.log ] ; then
    echo --- server log head and tail  ---
    echo ==================================================
    head -120 ${ETC_DIR}/aerospike.log | tail +90
    echo --------------------------------------------------
    tail -20 ${ETC_DIR}/aerospike.log
    echo ==================================================
fi

rm -rf ${ETC_DIR}

# if started agent for this script, kill it on the way out
if [ ${SSH_NOT_OK} -eq 1 ] ; then
    kill -15 ${SSH_AGENT_PID}
fi
