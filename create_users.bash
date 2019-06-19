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
PREFIX="mpi"
re_num='^[0-9]+$'


add_user() {
    if grep $USERNAME users.temp &> /dev/null
    then
        echo -n "$USERNAME: User exists - checking key..."
        if ! grep -Fx "$KEY" keys.temp/$USERNAME &> /dev/null
        then
            gcloud compute ssh $MASTERID $MZONE --command \
            "echo | sudo tee -a /home/$USERNAME/.ssh/authorized_keys &> /dev/null;
             echo \"# $USERNAME\" | sudo tee -a /home/$USERNAME/.ssh/authorized_keys &> /dev/null;
             echo \"$KEY\" | sudo tee -a /home/$USERNAME/.ssh/authorized_keys &> /dev/null;"
            echo > keys.temp/$USERNAME &> /dev/null;
            echo "# $USERNAME" > keys.temp/$USERNAME &> /dev/null;
            echo \"$KEY\" > keys.temp/$USERNAME &> /dev/null;
            echo -n "added key...";
        fi
        echo "done"
    else
        echo -n "$USERNAME: Creating new user..."
        gcloud compute ssh $MASTERID $MZONE --command \
        "sudo useradd -m -s /bin/bash \"$USERNAME\";
         echo | sudo tee -a /home/$USERNAME/.ssh/authorized_keys &> /dev/null;
         echo \"# $USERNAME\" | sudo tee -a /home/$USERNAME/.ssh/authorized_keys &> /dev/null;
         echo \"$KEY\" | sudo tee -a /home/$USERNAME/.ssh/authorized_keys &> /dev/null;"
        echo $USERNAME >> users.temp
        let "NUMVM=$(wc workers -l | cut -d ' ' -f 1)"
        for ((j=2;j<=NUMVM;j++))
        do
            WORKER=`sed "${j}q;d" workers`
            WORKERID=`echo $WORKER | cut -d ' ' -f 2`
            WZONE=`echo $WORKER | cut -d ' ' -f 3`
            WZONE="--zone $WZONE"
            gcloud compute ssh $WORKERID $WZONE --command "sudo useradd -M -s /bin/bash $USERNAME;" &> /dev/null
            echo -n '.'
        done
        echo "done"
    fi
}

ask_project() {
    if [[ $PSET == 0 ]]
    then
        echo -n "Project Name (leave blank to use default project $OLD_PROJECT): "
        read project

        if [[ $project != "" ]]
        then
            PROJECT=$project
            set_project $PROJECT
        fi
    fi

    touch workers.temp
    echo -n "Getting workers..."
    gcloud compute instances list > workers.temp
    echo "done"
}

get_worker() {
    WORKER=`sed "$(($1 + 1))q;d" workers.temp | grep "RUNNING" | sed 's/  \+/ /g' | cut -d ' ' -f 4`
    WORKER="$WORKER $(sed "$(($1 + 1))q;d" workers.temp | grep "RUNNING" | sed 's/  \+/ /g' | cut -d ' ' -f 1,2)"

    echo $WORKER | grep "${PREFIX}-0" &> /dev/null
    if [[ $? == 0 ]]
    then
        WORKER="$WORKER master"
        echo $WORKER > workers
    else
        echo $WORKER >> workers
    fi
}

get_workers() {
    NUMVM=`wc -l workers.temp | cut -d ' ' -f 1`
    let "NUMVM -= 1"

    for ((i=1;i<=NUMVM;i++))
    do
        get_worker $i
    done
}

# Validate username format
validate_username() {
    echo $USERNAME | grep " " &> /dev/null
    if [[ $? == 0 || $USERNAME == "" ]]
    then
        echo "$USERNAME: Skipping Username: Invalid Username"
        let "INVALID++"
    fi
}

# Validate key format
validate_key() {
    keywc=`echo $KEY | wc -w | cut -d ' ' -f 1`

    if [[ $KEY == "" || $keywc != 3 ]]
    then
        echo "$USERNAME: Skipping Username: Invalid SSH key"
        let "INVALID++"
    fi
}

# Automated entry from a .csv file  
auto_entry() {
    sed -i 's/"//g' $FILENAME

    # Get username column if necessary
    if [[ -z $USERCOL ]]
    then
        echo -n "Specify username column number: "
        read USERCOL
        if ! [[ $USERCOL =~ $re_num ]]
        then
            invalid_argument $USERCOL
        fi
    fi

    # Get key column if necessary
    if [[ -z $KEYCOL ]]
    then
        echo -n "Specify ssh key column number: "
        read KEYCOL
        if ! [[ $KEYCOL =~ $re_num ]]
        then
            invalid_argument $KEYCOL
        fi
    fi

    NUMKEY=`csvtool height $FILENAME`
    
    # Add all users
    for ((i=2;i<=NUMKEY;i++))
    do
        USERNAME=`csvtool col $USERCOL $FILENAME | sed "${i}q;d" | sed 's/"//g'`
        KEY=`csvtool col $KEYCOL $FILENAME | sed "${i}q;d" | sed 's/"//g'`

        INVALID=0
        validate_username
        validate_key
        if [ $INVALID -gt 0 ]; then continue; fi;
        add_user
    done

    echo
}


manual_entry() {
    while true 
    do
        echo
        echo -n "Enter new username (leave blank to quit): "
        read USERNAME

        if [[ $USERNAME == "" ]]
        then
            break
        fi

        echo -n "Enter SSH key for $USERNAME: "
        read KEY

        if [[ $KEY == "" ]]
        then
            break
        fi

        INVALID=0
        validate_username
        validate_key
        if [ $INVALID -gt 0 ]; then continue; fi;
        add_user
    done
}


source "./common.bash"

while test $# -gt 0
do
    case "$1" in
        -h|--help)
            echo "GCloud MPI Cluster User Setup Script"
            echo
            echo "Options:"
            echo "-h,   --help          show this help message"
            echo "-p,   --project ID    set the project to use (ID = full project id)"
            echo "      --prefix        specify the prefix to use when finding the head node (\$prefix-0)"
            echo
            echo "-f FILE               specify the .csv file (FILE) to use"
            echo "-k N                  specify the column number (N) with the ssh keys"
            echo "-u N                  specify the column number (N) with the usernames"
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
        --prefix)
            shift
            if test $# -gt 0
            then
                PREFIX="$1-"
                shift
            else
                missing_argument "--prefix"
            fi
            ;;
        *)
            echo "Unrecognized flag $1"
            exit 1
            ;;
    esac
done

if [[ $AUTO == 1 ]]
then
    # Check if csvtool is installed
    if ! apt list csvtool | grep "installed" &> /dev/null
    then
        if [ "$EUID" -ne 0 ]
        then 
            echo "Please install csvtool using:"
            echo "  sudo apt install csvtool"
            echo "to use automatic entry"
            exit 1
        fi
    fi
fi

ask_project
get_workers
config_master_vars

touch users.temp
echo -n "Finding users..."
gcloud compute ssh $MASTERID $MZONE --command "getent passwd | grep '/home' | cut -d ':' -f 1" > users.temp
USERS=`cat users.temp | tr '\n' ' '`
echo -n "keys..."
gcloud compute ssh $MASTERID $MZONE --command "mkdir keys.temp; for user in $USERS; do sudo cat /home/\$user/.ssh/authorized_keys > keys.temp/\$user; done;" &> /dev/null
gcloud compute scp $MZONE --recurse $MASTERID:keys.temp . &> /dev/null
echo "done"


if [[ $AUTO == 1 ]]
then
    echo "Automatic Entry"
    auto_entry
else
    echo "Manual Entry"
    manual_entry
fi

echo -n "Master Node IP..."
if [ -e workers.temp ]; then cat workers.temp | sed 's/  \+/ /g' | grep $MASTERID | cut -d ' ' -f 5;
else gcloud compute instances list | sed 's/  \+/ /g' | grep $MASTERID | cut -d ' ' -f 5; fi;

if [[ $PROJECT != $OLD_PROJECT ]]
then
    set_project $OLD_PROJECT
fi

if [ -e users.temp ]; then rm users.temp; fi;
if [ -e workers.temp ]; then rm workers.temp; fi;
if [ -e keys.temp ]; then rm -r keys.temp; fi;
