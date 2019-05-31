#!/bin/bash

USED_ZONES=''
OLD_PROJECT=`gcloud config list project 2> /dev/null | grep "project = " | cut -d ' ' -f 3`
PROJECT=$OLD_PROJECT
PREFIX="mpi-"
SAVEIMAGE=0


# Set the project being set up
set_project() {
    gcloud projects list | grep $1
    if [[ $? == 1 ]]
    then
        echo "Invalid project $1"
        exit 1
    fi

    gcloud config set project $1 &> /dev/null
}

# Ask user for the project they want to use
ask_project() {
    echo "Project Name (leave blank to use default project $OLD_PROJECT)"
    read project

    if [[ $project != "" ]]
    then
        PROJECT=$project
        set_project $PROJECT
    fi
}

# Ask if user wants to save the mpi-image
ask_save_img() {
    echo "Save image after setup? (y/N) (Saving image will incur costs)"
    read saveimg
    saveimg=`echo $saveimg | head -c1`
    if [[ $saveimg == 'y' || $saveimg == 'Y' ]]
    then 
        SAVEIMAGE=1
    fi
}

# Get a random zone from zones.txt
get_rand_zone() {
    z=$RANDOM
    numzones=`wc zones.txt -l | cut -d ' ' -f 1`
    let "z %= $numzones"
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
        get_rand_zone
        IMAGEZONE=$ZONE
        VMNAME="image-vm"
        
        gcloud compute instances create $VMNAME \
        --machine-type=n1-standard-2 --image-family=debian-9 \
        --image-project=debian-cloud --zone=$ZONE > /dev/null

        RET=$?
        if [[ $RET != 0 ]]
        then
            echo Exit code: $RET
            exit $RET
        fi

        gcloud compute scp mpi_setup.bash $VMNAME: --zone $ZONE
        gcloud compute ssh $VMNAME --zone $ZONE \
        --command "chmod +x mpi_setup.bash && sudo ./mpi_setup.bash && rm mpi_setup.bash"

        gcloud compute instances stop $VMNAME --zone $ZONE
        gcloud compute images create mpi-image --source-disk $VMNAME --source-disk-zone $IMAGEZONE > /dev/null

        gcloud compute instances delete $VMNAME --zone $ZONE --quiet
    fi
}

# Create the VMs
create_instances() {
    echo "Creating VMs"
    for ((i=0;i<NUMVM;i+=6))
    do
        get_rand_zone
        let "rem = $NUMVM - $i"

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
            echo Exit code: $RET
            exit $RET
        fi
    done

    if [[ $SAVEIMAGE == 0 ]]
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
            echo > mpihosts
        else
            echo "$LOCALIP $PREFIX$i $INSTANCEZONE" >> workers
            echo $PREFIX$i >> mpihosts
        fi
    done
}

# Set master environment variables
config_master_vars() {
    MASTER=`grep "master" workers`
    MASTERID=`echo $MASTER | cut -d ' ' -f 2`
    MASTERIDIP=`echo $MASTER | cut -d ' ' -f 1-2,4`
    MZONE=`echo $MASTER | cut -d ' ' -f 3`
    MZONE="--zone $MZONE"
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
     sudo cp ~/mpihosts /etc/skel; \
     sudo cp -r ~/.ssh .; \
     echo | sudo tee .ssh/authorized_keys &> /dev/null; \
     echo \"# Master\" | sudo tee -a .ssh/authorized_keys &> /dev/null; \
     cat ~/.ssh/id_rsa.pub | sudo tee -a .ssh/authorized_keys &> /dev/null; \
     sudo cp -r /etc/skel/CSinParallel ~"
}


echo "Number of VMs"
read NUMVM

re='^[0-9]+$'
if ! [[ $NUMVM =~ $re ]] ; then
   echo "error: Not a number" >&2; exit 1
fi

ask_project
ask_save_img

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
