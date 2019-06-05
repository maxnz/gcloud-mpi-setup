#!/bin/bash

OLD_PROJECT=`gcloud config list project 2> /dev/null | grep "project = " | cut -d ' ' -f 3`
PROJECT=$OLD_PROJECT
PSET=0
FILENAME=
AUTO=0
USERNAME=
KEY=
USERCOL=
KEYCOL=
re_num='^[0-9]+$'


invalid_argument() {
    if [ -z "$2" ]
    then
        echo "Invalid argument $1"
    else
        echo "Invalid argument $1 for flag '$2'"
    fi
    exit 1
}

missing_argument() {
    echo "Missing argument for $1"
    exit 1
}

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

add_user() {

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

}

ask_project() {
    if [[ $PSET == 0 ]]
    then
        echo "Project Name (leave blank to use default project $OLD_PROJECT)"
        read project

        if [[ $project != "" ]]
        then
            PROJECT=$project
            set_project $PROJECT
        fi
    fi

    touch workers.temp
    gcloud compute instances list > workers.temp

}

get_worker() {

    WORKER=`sed "$(($1 + 1))q;d" workers.temp | grep "RUNNING" | sed 's/  \+/ /g' | cut -d ' ' -f 4`
    WORKER="$WORKER $(sed "$(($1 + 1))q;d" workers.temp | grep "RUNNING" | sed 's/  \+/ /g' | cut -d ' ' -f 1,2)"

    echo $WORKER | grep "mpi-0" &> /dev/null
    if [[ $? == 0 ]]
    then
        WORKER="$WORKER master"
        echo $WORKER > workers
    else
        echo $WORKER >> workers
    fi
}

get_workers() {
    NUMVM=`gcloud compute instances list | wc -l | cut -d ' ' -f 1`
    let "NUMVM -= 1"

    for ((i=1;i<=NUMVM;i++))
    do
        get_worker $i
    done
    rm workers.temp
}

get_master() {
    MASTER=`grep "master" workers`
    MASTERID=`echo $MASTER | cut -d ' ' -f 2`
    MASTERIDIP=`echo $MASTER | cut -d ' ' -f 1-2,4`
    MZONE=`echo $MASTER | cut -d ' ' -f 3`
    MZONE="--zone $MZONE"
}

auto_entry() {
    apt list csvtool | grep "installed" &> /dev/null
    if [[ $? != 0 ]]
    then
        if [ "$EUID" -ne 0 ]
        then 
            echo "sudo required"
            exit
        else
            sudo apt install csvtool
        fi
    fi

    ask_project
    get_workers
    get_master

    if [[ -z $USERCOL ]]
    then
        echo "Specify user column number"
        read USERCOL
        if ! [[ $USERCOL =~ $re_num ]]
        then
            invalid_argument $USERCOL
        fi
    fi

    if [[ -z $KEYCOL ]]
    then
        echo "Specify key column number"
        read KEYCOL
        if ! [[ $KEYCOL =~ $re_num ]]
        then
            invalid_argument $KEYCOL
        fi
    fi

    NUMKEY=`csvtool height $FILENAME`
    
    for ((i=2;i<=NUMKEY;i++))
    do
        USERNAME=`csvtool col $USERCOL $FILENAME | sed "${i}q;d"`
        KEY=`csvtool col $KEYCOL $FILENAME | sed "${i}q;d"`
        echo $USERNAME
        echo $KEY

        add_user
    done

    echo
}


manual_entry() {

    ask_project
    get_workers
    get_master

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
        add_user
    done
}



while test $# -gt 0
do
    case "$1" in
        -h|--help)
            echo "GCloud MPI Cluster Setup Script"
            echo
            echo "Options:"
            echo "-h,   --help          show this help message"
            echo "-k N                  specify the column number with the ssh keys"
            echo "-p,   --project ID    set the project to use (ID = full project id)"
            echo "-u N                  specify the column number with the usernames"
            exit -1
            ;;
        -f)
            shift
            if test $# -gt 0
            then
                FILENAME=$1
                AUTO=1
                shift
            else
                missing_argument "-f"
            fi
            ;;
        -p|--project)
            shift
            PSET=1
            if test $# -gt 0
            then
                set_project $1
                shift
            else
                missing_argument "-p|--project"
            fi
            ;;
        -u)
            shift
            if test $# -gt 0
            then
                USERCOL=$1
                if ! [[ $USERCOL =~ $re_num ]]
                then
                    invalid_argument $USERCOL "-u"
                fi
                shift
            else
                missing_argument "-u"
            fi
            ;;
        -k)
            shift
            if test $# -gt 0
            then
                KEYCOL=$1
                if ! [[ $KEYCOL =~ $re_num ]]
                then
                    invalid_argument $KEYCOL "-k"
                fi
                shift
            else
                missing_argument "-k"
            fi
            ;;
        *)
            echo "Unrecognized flag $1"
            shift
            ;;
    esac
done

if [[ $AUTO == 1 ]]
then
    echo "A"
    auto_entry
else
    echo "M"
    manual_entry
fi

echo -n "Master Node IP..."
gcloud compute instances list | sed 's/  \+/ /g' | grep $MASTERID | cut -d ' ' -f 5

if [[ $PROJECT != $OLD_PROJECT ]]
then
    set_project $OLD_PROJECT
fi
