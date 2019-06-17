#!/bin/bash

USED_ZONES=
NUMUSEDZONES=0
OLD_PROJECT=`gcloud config list project 2> /dev/null | grep "project = " | cut -d ' ' -f 3`
PROJECT=
PREFIX="mpi-"           # Must start with a letter
SAVEIMAGE=-1
NUMVM=-1
CORESPERVM=2
re_num='^[0-9]+$'
QUIET=0


# Ask user for the project they want to use
ask_project() {
    echo -n "Project Name (leave blank to use current project $OLD_PROJECT): "
    read project

    if [[ $project != "" ]]
    then
        set_project $project
    else
        set_project $OLD_PROJECT
    fi
}

# Ask if user wants to save the mpi-image
ask_save_img() {
    echo -n "Saving MPI image will incur costs. Save image after setup? (y/N): "
    read saveimg
    saveimg=`echo $saveimg | head -c1`
    if [[ $saveimg == 'y' || $saveimg == 'Y' ]]
    then 
        SAVEIMAGE=1
    fi
}

# Get a random zone from zones.txt
get_rand_zone() {
    if [[ $NUMUSEDZONES == 20 ]]
    then
        echo "No remaining zones"
        exit 1
    fi
    z=$RANDOM
    numzones=`wc zones.txt -l | cut -d ' ' -f 1`
    let "z %= $numzones"
    let "z++"
    ZONE=`sed "${z}q;d" zones.txt`
    zonec=`echo $ZONE | cut -d '-' -f 1`
    zonel=`echo $ZONE | cut -d '-' -f 2`
    zone="${zonec}-${zonel}"
    echo $USED_ZONES | grep $zone &> /dev/null
    if [[ $? == 0 ]]
    then
        get_rand_zone
    else
        USED_ZONES="$USED_ZONES $ZONE"
        let "NUMUSEDZONES++"

        touch quotas.temp
        gcloud compute regions describe $zone > quotas.temp

        LINES=`wc quotas.temp -l | cut -d ' ' -f 1`
        for ((j=1;j<=LINES;j++))
        do
            LINE=`sed "${j}q;d" quotas.temp`
            echo $LINE | grep "limit:" &> /dev/null
            if [[ $? == 0 ]]
            then
                sed "$(($j+1))q;d" quotas.temp | grep "CPUS" &> /dev/null
                if [[ $? == 0 ]]
                then
                    REGCPUUSAGE=`sed "$(($j+2))q;d" quotas.temp | sed 's/  \+/ /g' | cut -d ' ' -f 3 | cut -d '.' -f 1`
                    REGCPUQUOTA=`sed "${j}q;d" quotas.temp | sed 's/  \+/ /g' | cut -d ' ' -f 3 | cut -d '.' -f 1`
                    let "REGREMCPUS = $REGCPUQUOTA - $REGCPUUSAGE"
                    if [ $REGREMCPUS -lt $1 ]
                    then
                        echo "Not enough CPUs remaining in region quota: $REGREMCPUS remaining in $zone"
                        get_rand_zone
                    fi
                    break
                fi
            fi
        done
        rm quotas.temp
    fi
}

get_quota() {
    touch quotas.temp
    gcloud compute project-info describe --project $PROJECT > quotas.temp

    LINES=`wc quotas.temp -l | cut -d ' ' -f 1`
    for ((i=1;i<=LINES;i++))
    do
        LINE=`sed "${i}q;d" quotas.temp`

        echo $LINE | grep "limit:" &> /dev/null
        if [[ $? == 0 ]]
        then
            sed "$(($i+1))q;d" quotas.temp | grep "CPUS_ALL_REGIONS" &> /dev/null
            if [[ $? == 0 ]]
            then
                CPUUSAGE=`sed "$(($i+2))q;d" quotas.temp | sed 's/  \+/ /g' | cut -d ' ' -f 3 | cut -d '.' -f 1`
                CPUQUOTA=`sed "${i}q;d" quotas.temp | sed 's/  \+/ /g' | cut -d ' ' -f 3 | cut -d '.' -f 1`
                let "REMCPUS = $CPUQUOTA - $CPUUSAGE"
                if [ $REMCPUS -lt $VMCORES ]
                then
                    echo "Not enough CPUs remaining in overall quota: $REMCPUS remaining"
                    rm quotas.temp
                    exit 1
                fi
                break
            fi
        fi
    done
    rm quotas.temp
}

confirm_opts() {
    echo
    echo "Configuration:"
    echo "Project:           $PROJECT"
    echo "Cluster Size:      $NUMVM VMs"
    echo -n "Save MPI Image:    "
    if [[ $SAVEIMAGE == 1 ]]; then echo "YES"; else echo "NO"; fi;
    if [[ $QUIET == 1 ]]; then return; fi;
    echo -n "Continue? (Y/n): "
    read con
    con=`echo $con | head -c1`
    if [[ $con == 'n' || $con == 'N' ]]
    then
        echo "Abort"
        exit -1
    fi
}


# Create MPI image
create_image() {
    # check if image exists
    gcloud compute images list | grep "mpi-image" &> /dev/null
    CONTAINSIMAGE=$?

    if [[ $CONTAINSIMAGE == 1 ]]
    then
        echo "Creating new MPI image"
        get_rand_zone 2
        IMAGEZONE=$ZONE
        VMNAME="image-vm"
        
        RET=1
        while [[ $RET != 0 ]]
        do
            gcloud compute instances create $VMNAME \
            --machine-type=n1-standard-2 --image-family=debian-9 \
            --image-project=debian-cloud --zone=$ZONE > /dev/null

            RET=$?
        done


        gcloud compute scp mpi_setup.bash $VMNAME: --zone $ZONE
        gcloud compute ssh $VMNAME --zone $ZONE \
        --command "chmod +x mpi_setup.bash && sudo ./mpi_setup.bash && rm mpi_setup.bash"

        gcloud compute instances stop $VMNAME --zone $ZONE
        gcloud compute images create mpi-image --source-disk $VMNAME --source-disk-zone $IMAGEZONE > /dev/null

        gcloud compute instances delete $VMNAME --zone $ZONE --quiet
    else
        echo "Using existing MPI image"
    fi
}

# Create the VMs
create_instances() {
    echo "Creating VMs"
    for ((i=0;i<NUMVM;i+=6))
    do
        let "rem = $NUMVM - $i"
        if [ $rem -gt 5 ]; then corect=6; else corect=$rem; fi;
        let "corect *= $CORESPERVM"
        get_rand_zone $corect

        if [[ $rem == 1 ]]
        then
            gcloud compute instances create \
            --machine-type=n1-standard-2 --image=mpi-image \
            --image-project=$PROJECT --zone=$ZONE \
            $PREFIX$i > /dev/null
        elif [[ $rem == 2 ]]
        then
            gcloud compute instances create \
            --machine-type=n1-standard-2 --image=mpi-image \
            --image-project=$PROJECT --zone=$ZONE \
            $PREFIX$i $PREFIX$(($i+1)) > /dev/null
        elif [[ $rem == 3 ]]
        then
            gcloud compute instances create \
            --machine-type=n1-standard-2 --image=mpi-image \
            --image-project=$PROJECT --zone=$ZONE \
            $PREFIX$i $PREFIX$(($i+1)) $PREFIX$(($i+2)) > /dev/null
        elif [[ $rem == 4 ]]
        then
            gcloud compute instances create \
            --machine-type=n1-standard-2 --image=mpi-image \
            --image-project=$PROJECT --zone=$ZONE \
            $PREFIX$i $PREFIX$(($i+1)) $PREFIX$(($i+2)) $PREFIX$(($i+3)) > /dev/null
        elif [[ $rem == 5 ]]
        then
            gcloud compute instances create \
            --machine-type=n1-standard-2 --image=mpi-image \
            --image-project=$PROJECT --zone=$ZONE \
            $PREFIX$i $PREFIX$(($i+1)) $PREFIX$(($i+2)) $PREFIX$(($i+3)) $PREFIX$(($i+4)) > /dev/null
        else
            gcloud compute instances create \
            --machine-type=n1-standard-2 --image=mpi-image \
            --image-project=$PROJECT --zone=$ZONE \
            $PREFIX$i $PREFIX$(($i+1)) $PREFIX$(($i+2)) $PREFIX$(($i+3)) $PREFIX$(($i+4)) $PREFIX$(($i+5)) > /dev/null
        fi
        RET=$?
        if [[ $RET != 0 ]]
        then
            echo "Exception while creating VMs. Please delete existing VMs and try again."
            echo Exit code: $RET
            exit $RET
        fi
    done

    if [[ $SAVEIMAGE != 1 ]]
    then 
        gcloud compute images delete mpi-image --quiet
    fi

}

# Create the workers file
create_workers_txt() {
    if ! [ -e workers ]; then touch workers; fi;
    if ! [ -e mpihosts ]; then touch mpihosts; fi;
    for ((i=0;i<NUMVM;i++))
    do
        DETAILS=`gcloud compute instances list | sed 's/  \+/ /g' | grep "$PREFIX$i "`
        LOCALIP=`echo $DETAILS | cut -d ' ' -f 4`
        INSTANCEZONE=`echo $DETAILS | cut -d ' ' -f 2`

        if [[ $i == 0 ]]
        then
            echo "$LOCALIP $PREFIX$i $INSTANCEZONE master" > workers
            echo $PREFIX$i > mpihosts
        else
            echo "$LOCALIP $PREFIX$i $INSTANCEZONE" >> workers
            echo $PREFIX$i >> mpihosts
        fi
    done
}

# Configure master
config_master() {
    echo "---MASTER 0---"
    gcloud compute ssh $MASTERID $MZONE --command \
    "echo $MASTERIDIP | sudo tee -a /etc/hosts; \
     ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa && cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys; \
     if [ ! -e ~/.ssh/config ]; then touch ~/.ssh/config; echo \"StrictHostKeyChecking no\" > ~/.ssh/config; fi; \
     echo \"/home *(rw,sync,no_root_squash,no_subtree_check)\" | sudo tee -a /etc/exports; \
     cd /; sudo exportfs -a; sudo service nfs-kernel-server restart;" &> /dev/null

    MASTERKEY=`gcloud compute ssh $MASTERID $MZONE --command "cat ~/.ssh/id_rsa.pub"`
}

# Configure a worker
config_worker() {
    WORKER=`sed "$(($1 + 1))q;d" workers`
    WORKERID=`echo $WORKER | cut -d ' ' -f 2`
    WORKERIPID=`echo $WORKER | cut -d ' ' -f 1-2`
    WZONE=`echo $WORKER | cut -d ' ' -f 3`
    WZONE="--zone $WZONE"
    echo "---WORKER $1---"

    gcloud compute ssh $WORKERID $WZONE --command \
    "ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa; \
     touch ~/.ssh/config; \
     echo \"StrictHostKeyChecking no\" > ~/.ssh/config; \
     echo >> ~/.ssh/authorized_keys; \
     echo \"# $MASTERID\" >> ~/.ssh/authorized_keys; \
     echo \"$MASTERKEY\" >> ~/.ssh/authorized_keys; \
     echo | sudo tee -a /etc/hosts; \
     echo \"# MPI\" | sudo tee -a /etc/hosts; \
     echo \"$MASTERIDIP\" | sudo tee -a /etc/hosts; \
     echo \"$WORKERIPID\" | sudo tee -a /etc/hosts; \
     cd /; sudo mount -t nfs master:/home /home; \
     echo \"master:/home /home nfs\" | sudo tee -a /etc/fstab;" &> /dev/null

    WORKERKEY=`gcloud compute ssh $WORKERID $WZONE --command "cat ~/.ssh/id_rsa.pub"`

    gcloud compute ssh $MASTERID $MZONE --ssh-flag="-tt" --command \
    "echo $WORKERIPID | sudo tee -a /etc/hosts; \
     echo >> ~/.ssh/authorized_keys; \
     echo \"# $WORKERID\" >> ~/.ssh/authorized_keys; \
     echo \"$WORKERKEY\" >> ~/.ssh/authorized_keys; \
     ssh $WORKERID -t \"exit\"" &> /dev/null
}

# Populate /etc/skel
setup_skel() {
    echo "Setting up /etc/skel for new users"
    gcloud compute scp mpihosts $MASTERID: $MZONE &> /dev/null
    gcloud compute ssh $MASTERID $MZONE --command \
    "cd /etc/skel; \
     sudo wget http://csinparallel.cs.stolaf.edu/CSinParallel.tar.gz; \
     sudo tar -xf CSinParallel.tar.gz && sudo rm CSinParallel.tar.gz; \
     for file in \$(sudo find /etc/skel/CSinParallel -name cluster_nodes); do sudo cp ~/mpihosts \$file; done; \
     sudo cp -r ~/.ssh .; \
     echo | sudo tee .ssh/authorized_keys &> /dev/null; \
     echo \"# Master\" | sudo tee -a .ssh/authorized_keys &> /dev/null; \
     cat ~/.ssh/id_rsa.pub | sudo tee -a .ssh/authorized_keys &> /dev/null; \
     sudo cp -r /etc/skel/CSinParallel ~; \
     sudo chmod -R 777 ~/CSinParallel;"
}


source "./common.bash"

while test $# -gt 0
do
    case "$1" in
        -h|--help)
            echo "GCloud MPI Cluster Setup Script"
            echo
            echo "Options:"
            echo "-h,   --help          show this help message"
            echo "-p,   --project ID    set the project to use (ID = full project id)"
            echo
            echo "-q,   --quiet         run the script with default options (unless specified otherwise):"
            echo "                          current project, 8 VMs, delete image"
            echo "-n  N                 set the number of nodes (N) in the cluster"
            echo "-d,   --delete-image  delete the MPI image after creating VMs (Default)"
            echo "-s,   --save-image    save the MPI image after creating VMs (this will incur costs)"
            exit -1
            ;;
        -q|--quiet)
            shift
            if [[ $SAVEIMAGE == -1 ]] ; then SAVEIMAGE=0; fi;
            if [[ $PROJECT == "" ]]; then PROJECT=$OLD_PROJECT; fi;
            if [[ $NUMVM == -1 ]]; then NUMVM=8; fi;
            QUIET=1
            ;;
        -n)
            shift
            if test $# -gt 0
            then
                NUMVM=$1
                if ! [[ $NUMVM =~ $re_num ]]
                then
                    invalid_argument $NUMVM "-n"
                fi
                shift
            else
                missing_argument "-n"
            fi
            ;;
        -s|--save-image)
            SAVEIMAGE=1
            shift
            ;;
        -d|--delete-image)
            SAVEIMAGE=0
            shift
            ;;
        -p|--project)
            shift
            if test $# -gt 0
            then
                set_project $1
                shift
            else
                missing_argument "-p|--project"
            fi
            ;;
        *)
            echo "Unrecognized flag $1"
            exit 1
            ;;
    esac
done

if [[ $PROJECT == "" ]]
then
    ask_project
fi

if [[ $NUMVM == -1 ]]
then
    echo -n "Number of VMs: "
    read NUMVM

    re='^[0-9]+$'
    if ! [[ $NUMVM =~ $re ]] ; then
       invalid_argument $NUMVM
    fi
fi
let "VMCORES= $CORESPERVM * $NUMVM"

if [[ $SAVEIMAGE == -1 ]]
then
    ask_save_img
fi

get_quota
confirm_opts
create_image
create_instances
create_workers_txt

gcloud compute config-ssh &> /dev/null

echo "Configuring VMs"
config_master_vars
config_master

for ((i=1;i<NUMVM;i++)); do
    config_worker $i
done

setup_skel

if [[ $PROJECT != $OLD_PROJECT ]]
then
    set_project $OLD_PROJECT
fi
