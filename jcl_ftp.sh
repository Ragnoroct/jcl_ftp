#!/bin/bash

HOST='zos.kctr.marist.edu'
NEWPROMPT="\nNew prompt ********************************************************************************\n\n"
#export PROGRESS=""

#Get the directory the submit script is stored in
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, 
done                                           #we need to resolve it relative to the path where the symlink file was located
#Directory of this script
DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

#Name for log of output from this script
LOGNAME="$DIR/log.txt"
echo > "$LOGNAME"

configfile="${DIR}/config.txt"
configfile_secured="${DIR}/tmp/cool.cfg"

# check if the config file contains something we don't want
if egrep -q -v '^#|^[^ ]*=[^;]*' "$configfile"; then
  echo "Config file is unclean, cleaning it..." >&2
  # filter the original to a new file
  egrep '^#|^[^ ]*=[^;&]*'  "$configfile" > "$configfile_secured"
  configfile="$configfile_secured"
fi


# now source it, either the original or the filtered variant
source "$configfile"

#Set up tmp folder
if [ ! -d "${DIR}/tmp" ]; then
     mkdir "${DIR}/tmp"
fi

#Takes stdin and looks for the job id
#Echos stdout to read to output the jobid
function read_output {
     jobid=""
	while read line
	do	     
		#Output from functions to debug
		if $DEBUG; then
		     echo "$line" >> $LOGNAME
		fi
		
		#Split line into an array
		read -r -a array <<< "$line"
          for str in ${array[@]}; do
               if [ "${str:0:3}" = "JOB" ]; then
                   jobid="$str"
               fi
          done
  	done
  	echo "$jobid"
  	echo "End of pipe function" >> $LOGNAME
}

function read_get {
     while read line
     do
          echo "$line" >> "$LOGNAME"
          if [ "${line:0:3}" = "550" ]; then
               status="fail"
          fi
     done
     
     echo "$status"     
     return
}

function putftp {
cmd=$(
     #Log into ftp
     if $NETRC; then
          #Using .netrc
          echo "ftp -v -i $HOST << EOT"
     else
          #Using provided passwd and username
          echo "ftp -n -v -i $HOST << EOT"
          echo "ascii"
          echo "user $USER $PASSWD"
     fi
     
     #Issue commands
     echo "prompt"
     echo "passive"
     echo "quote site filetype=jes"
     echo "put $1"
     echo "bye"
     echo "EOT"
)
eval "$cmd"
}

function getftp {
cmd=$(
     #Log into ftp
     if $NETRC; then
          #Using .netrc
          echo "ftp -v -i $HOST << EOT"
     else
          #Using provided passwd and username
          echo "ftp -n -v -i $HOST << EOT"
          echo "ascii"
          echo "user $USER $PASSWD"
     fi
     
     #Issue commands
     echo "prompt"
     echo "passive"
     echo "quote site filetype=jes"
     echo "ls"
     echo "get $1"
     echo "del $1"
     echo "bye"
     echo "EOT"
)
eval "$cmd"
}

function lsftp {
cmd=$(
     #Log into ftp
     if $NETRC; then
          #Using .netrc
          echo "ftp -v -i $HOST << EOT"
     else
          #Using provided passwd and username
          echo "ftp -n -v -i $HOST << EOT"
          echo "ascii"
          echo "user $USER $PASSWD"
     fi
     
     #Issue commands
     echo "prompt"
     echo "passive"
     echo "quote site filetype=jes"
     echo "ls"
     echo "bye"
     echo "EOT"
)
eval "$cmd"
}

#Attempts to connect to fpt through user and passwd given
function connectftp {
     failure="Login failed."
     {    #Check if connect was successful
          while read line;
          do
               #echo "$line" >> "LOGNAME"
               echo "$line"
               if [ "$line" = "$failure" ]; then
                    echo "Couldn't connect" >> "$LOGNAME"
                    status=1  #Failure, try again
               fi
               if [ "${line:0:3}" = "230" ]; then
                    echo "Succesfully connected" >> "$LOGNAME"
                    status=0 #Success, proceed
               fi
          done
          #Try to connect to ftp
     } < <(ftp -n -i -v $HOST << EOT
user $USER $PASSWD
bye
EOT
)

     return $status
}

function submitjob {
     TIMEOUT=2           #How long to wait to get file
     TRIES=5             #How many attempts to retrieve file
     count=0             #Keep track of time

     #This function is used to clean up at the end, error or no error
     function endfunct() {
          #Kill progress and wait for it to end
          kill $pid 2>/dev/null
          wait $pid 2>/dev/null
     }
     
     #ts="10#$(date +%s%N)"                       #Get starting time in miliseconds
     #read rate < "$TIMEFILE"                 #Get rate of transfer from TIMEFILE in bytes/sec    
     #filesize=$(stat -c%s "$1")              Get file size
     #filesize=$(wc -c $1 | awk ‘{print $1}’)
     #filesize=$(wc -c < $1)

      #filesize=$(echo boobs)
     clear
     progress "Submitting file" &
     pid=$! 
     #export -f PROGRESS="0.00"
     #progress $rate $filesize &              #Start progress bar and store pid
                          
     
     #Submit job
     read jobid < <(putftp $1 | read_output) #Submit file and get job-id
     echo -e "\n\n" >> $LOGNAME
     export -f PROGRESS=".33"

     kill $pid 2&>/dev/null
     wait $pid 2>/dev/null
     clear
     progress "Retreiving file" &
     pid=$!
     
     #Attempt to fetch job
     n=0
     until [ $n -ge 5 ]
     do
          read st < <(getftp $jobid | read_get)        #Try to retrieve job
          if [ ! "$st" = "fail" ]; then break; fi      #End loop if return status != fail
          n=$[$n+1]
     done
     if [ $n -eq 5 ]; then
          ERROR="UNKNOWN ERROR: Job could not be fetched"
          return       #End function
     fi

     kill $pid 2&>/dev/null
     wait $pid 2>/dev/null
     clear
     progress "Waiting for file" &
     pid=$!
     sleep 1

     #Wait for output to download
     file="$PWD/$jobid"
     stop=$(( SECONDS + TIMEOUT ))
     while true
     do 
          if [ -f $file ]; then break; fi;   #Break if file is found
          if [ "$SECONDS" -gt "$stop" ]; then
               ERROR="UNKNOWN ERROR: Job output could not be found."
               return       #End function
          fi
          sleep .1
     done

     STATUS="Successfully submited job."
     
     
     mv "$jobid" "$FILE.out"               #Change name to namefile.out
     
     #Save output file in universal location
     if [ ! "$OUTDIR" = "" ]; then           #Check if universal dir is set
          if [ ! -d "$OUTDIR" ]; then        #Check if it exist
               mkdir "$OUTDIR"               #Create if it doesn't
          fi
          mv "${FILE}.out" "$OUTDIR"   #Move output to directory
     else
          #Save output in current location
          if [ "$OUTFOLDER" ]; then               #Store in OUTFOLDER if specified
               if [ ! -d "${PWD}/OUTPUT" ]; then  #Check if dir exists
                    mkdir OUTPUT                  #Create it if it doesnt
               fi
               mv "${FILE}.out" "${PWD}/OUTPUT"   #Move output to directory
          fi
     fi        
     #If none of the if statements were run, file stays right where it is 

     kill $pid 2>/dev/null
     wait $pid 2>/dev/null
}

function purgejobs {
     getting=false  #Currently not retreiving jobs ids
     id_list=()     #Array of job ids

     while IFS='' read -r line; do
          #Turn read line and store in array
          if $DEBUG; then
               echo $line >> $LOGNAME
          fi
          read -r -a array <<< "$line"
          first="${array[0]}";
         	second="${array[1]}";
         	
          #Read in each jobid
          if [[ "$first" == "$USER"* ]];
          then
               id_list+=("$second")
          fi
          
  	done < <(lsftp)
  	
     length=${#id_list[@]}
     
     if (( $length == 0 )); then
          STATUS="There are no jobs to delete."
          return
     fi
  	
  	script="${DIR}/tmp/ftpscript"
  	
  	echo > $script       #Create new script
  	#Set up connection
  	if ! $NETRC; then
  	     echo "ascii" >> $script
  	     echo "user $USER $PASSWD" >> $script
  	fi
     echo "prompt" >> $script
     echo "passive" >> $script
     echo "quote site filetype=jes" >> $script
     #Enter in del commands
     for i in "${id_list[@]}"
     do
          echo "del $i" >> $script
     done
     #End script
     echo "bye" >> $script
     
     #Use ftp through echo'd script through netrc or user and passwd
     if $NETRC; then
          #Using .netrc
          (ftp -v -i $HOST < $script) >> "$LOGNAME"         #Log in without .netrc
     else
          #Using provided passwd and username
          (ftp -inv $HOST < $script) >> "$LOGNAME"          #Log in with .netrc
     fi
     STATUS="Successfully deleted $length jobs."
}

# $1 is rate to submit file in bytes/miliseconds
# $2 is size of current file being submitted
function progress {
     echo -en "$1 "
     sp='/-\|'
     printf ' '
     while true; do
         printf '\b%.1s' "$sp"
         sp=${sp#?}${sp%???}
     done
}

chr() {
  [ "$1" -lt 256 ] || return 1
  printf "\\$(printf '%03o' "$1")"
}

ord() {
  LC_CTYPE=C printf '%d' "'$1"
}

function prompt {
     echo -e "$NEWPROMPT" >> "$LOGNAME"
     clear
     #Show current directory and listing of files
     echo "Directory: $PWD"        #Directory
     echo "Sub-dirs: "
     ls -d */                      #List directories
     echo -n "Files: "
     if $ONLYJCL; then   
          ls *.jcl         #Only .jcl files
     else
          cols=`tput cols`         #Get number of columns
          cols=$(( cols - 7 ))     #Subtract 7 for "Files: "
          #List files
          fold -s -w $cols <(ls -p | grep -v / | tr '\n' ' '); echo;
     fi
     #Check if ERROR or STATUS have any strings to output
     if [ ! "$ERROR" = "" ];then
          echo "$ERROR"
     fi
     if [ ! "$STATUS" = "" ];then
          echo "$STATUS"
     fi
     
     #Give prompt and ask for user input
     echo
     echo "1) Submit JCL Job"
     echo "2) Resubmit JCL Job"
     echo "3) Purge lingering jobs"
     echo "4) CD to different directory"
     echo "5) Exit Program"
     read -p "Enter option number [default=2]: " num
     echo
     #If number is 0 enter was pressed
     if [ "$num" == "" ]; then
          num=2
          return $num
     fi
     #Check to see if input is a number 0-9
     re='^[0-9]+$'
     if ! [[ "$num" =~ $re ]]
     then
          return `ord "$num"`
     fi
     return $num
}
#***************************************************************************************************************
#Main program
#Variables used in main loop
FILE=""        #File to submit to ftp
LASTFILE=""    #Last file to submit to ftp

ERROR=""       #Printed before prompt to show any errors
STATUS=""      #Printed before prompt to show success

EXIT=5         #Number pressed to exit program

#If OUTFOLDER is specified, create it if it doesn't exist
if $OUTFOLDER; then
     if [ ! -d "${PWD}/OUTPUT" ]; then
          mkdir OUTPUT
     fi
fi

#Check for .netrc
NETRC="$HOME/.netrc"
grep -q $HOST $NETRC
rs=$?
if [ $rs -eq 0 ]; then
     chmod 777 "$HOME/.netrc"  #Change permissions to grep it
     NETRC=true
     USER=$(awk '/zos.kctr.marist.edu/{getline; print $2}' $HOME/.netrc)  #Get username             
     USER=`echo "$USER" | tr '[:lower:]' '[:upper:]'`                 #Conver username to all uppercase
     STATUS="Using .netrc file with username $USER"
     chmod 600 "$HOME/.netrc"  #Change back permissions
else
     STATUS="Host info not provided in .netrc or .netrc doesn't exist"
     #Get username and password
     while true
     do
          NETRC=false
          clear
          echo -e "$STATUS"
          echo -n "Enter KC-ID: "
          read USER
          echo -n "Enter Password: "
          read -s PASSWD
          echo
          connectftp $>> "$LOGNAME"    #Try to connect
          st=$?          #Get return status
          USER=$(echo "$USER" | tr '[:lower:]' '[:upper:]')          #Conver username to all uppercase
          if (( $st == 0 )); then
               STATUS="Logged in as user $USER"
               break
          else
               STATUS="ERROR: Incorrect user or password. Could not connect. Try again."
          fi
     done
fi


#Get first user input
prompt    #Get first command given
st=$?     #Store return value

#Command loop
while [ ! "$st" = "$EXIT" ];
do
     
     ERROR=""       #Init. as empty
     STATUS=""      #Init. as empty
     #Case statement to catch user input
     case $st in
     1)   #Submit job through entered name
          read -p 'Enter name of file: ' FILE
          if [ -f "$FILE" ]; then
               echo "Submitting job..."
               submitjob "$FILE"
               LASTFILE="$FILE"
          else
               ERROR="Error: ($FILE) does not exists."
          fi
          ;;
     2)   #Resubmit last job
          if [ ! "$LASTFILE" = "" ]; then
               echo "Resubmitting last job.."
               submitjob "$LASTFILE"
          else
               echo ""
               ERROR="Error: No last job to resubmit"
          fi
          ;;
     3)   #Remove any lingering jobs
          purgejobs >> "$LOGNAME"
          st=$?
          ;;
     4)   #Ask user to enter a valid directory and cd into it
          read -p 'Enter cd input: ' input
          if cd "$input" 2> /dev/null; then
               :
          else
               if [ "${input:0:1}" = "/" ]; then
                    ERROR="ERROR: Directory (${input}/) doesn't exist."
               else
                    ERROR="ERROR: Directory (${PWD}/${input}/) doesn't exist."
               fi
          fi
          ;;
     *)   #Invalid option
          if (( "$st" < 0 )) || (( "$st" > 9 )); then
               ERROR="Invalid option(`chr \"$st\"`): Try again"    #Character input
          else
               ERROR="Invalid option($st): Try again"            #Unused option
          fi
          ;;
     esac
     prompt
     st=$?
done

chmod ugo-w "$TIMEFILE"  #Remove permissions to edit file

clear
echo "Exiting program..."
sleep .5
clear
