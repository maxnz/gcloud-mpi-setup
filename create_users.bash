#!/bin/bash

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

OLD_PROJECT=`gcloud config list project 2> /dev/null | grep "project = " | cut -d ' ' -f 3`
PROJECT=$OLD_PROJECT

echo "Project Name (leave blank to use default project $OLD_PROJECT)"
read project

if [[ $project != "" ]]
then
    PROJECT=$project
    set_project $PROJECT
fi

MASTER=`grep "master" workers`
MASTERID=`echo $MASTER | cut -d ' ' -f 2`
MASTERIDIP=`echo $MASTER | cut -d ' ' -f 1-2,4`
MZONE=`echo $MASTER | cut -d ' ' -f 3`
MZONE="--zone $MZONE"

gcloud compute instances list | sed 's/  \+/ /g' | grep $MASTERID | cut -d ' ' -f 5

while true 
do
    echo "Enter new username (leave blank to quit)"
    read USERNAME

    if [[ $USERNAME == "" ]]
    then
        break
    fi

    echo "Enter new user's SSH key"
    read KEY
    
    keywc=`echo $KEY | wc -w | cut -d ' ' -f 1`

    if [[ $KEY == "" ]]
    then
        break
    elif [[ $keywc != 3 ]]
    then
        echo "Need 3 fields"
        break
    fi

    RET=`gcloud compute ssh $MASTERID $MZONE --command \
    "sudo useradd -m -s /bin/bash $USERNAME;" 2>&1`

    echo $RET | grep "already exists" &> /dev/null
    RET=$?
    RET2=1

    if [[ $RET == 0 ]]
    then
        echo "User $USERNAME exists - checking key"

        gcloud compute ssh $MASTERID $MZONE --command "sudo cat /home/$USERNAME/.ssh/authorized_keys" | \
        grep -Fx "$KEY" &> /dev/null
        if [[ $? == 0 ]]; then RET2=0; fi;
    else
        echo "Creating new user $USERNAME"
    
        let "NUMVM=$(wc workers -l | cut -d ' ' -f 1)"
        for ((i=2;i<=NUMVM;i++))
        do
            WORKER=`sed "${i}q;d" workers`
            WORKERID=`echo $WORKER | cut -d ' ' -f 2`
            WZONE=`echo $WORKER | cut -d ' ' -f 3`
            WZONE="--zone $WZONE"
            gcloud compute ssh $WORKERID $WZONE --command "sudo useradd -M -s /bin/bash $USERNAME;" &> /dev/null
            echo -n '.'
        done
        echo
    fi

    if [[ $RET2 == 1 ]]
    then
        echo "Adding new SSH key"

        gcloud compute ssh $MASTERID $MZONE --command \
        "echo | sudo tee -a /home/$USERNAME/.ssh/authorized_keys &> /dev/null; \
         echo \"# $USERNAME\" | sudo tee -a /home/$USERNAME/.ssh/authorized_keys &> /dev/null; \
         echo \"$KEY\" | sudo tee -a /home/$USERNAME/.ssh/authorized_keys &> /dev/null;"
    fi
    echo
done

if [[ $PROJECT != $OLD_PROJECT ]]
then
    set_project $OLD_PROJECT
fi
