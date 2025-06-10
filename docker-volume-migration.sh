#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DRY_RUN_MODE=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN_MODE=true
            echo -e "${YELLOW}Dry run mode enabled. No changes will be made.${NC}"
            ;;
    esac
done

execute_command() {
    local cmd="$@"
    if "$DRY_RUN_MODE"; then
        echo -e "${YELLOW}DRY RUN:${NC} $cmd"
    else
        eval "$cmd"
    fi
}


if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker is not installed. Please install Docker first.${NC}"
    exit 1
fi

while true; do
    read -p "$(echo -e "${YELLOW}Enter the remote host IP or hostname (not localhost): ${NC}")" HOST
    if [[ "$HOST" != "localhost" && -n "$HOST" ]]; then
        break
    else
        echo -e "${RED}Invalid input. Please enter a valid remote host IP or hostname (not localhost).${NC}"
    fi
done

while true; do
    read -p "$(echo -e "${YELLOW}Enter the path to your private SSH key file (e.g., /path/to/id_rsa): ${NC}")" SSH_KEY
    if [[ -f "$SSH_KEY" ]]; then
        break
    else
        echo -e "${RED}Invalid file path. Please enter a valid path to your private SSH key file.${NC}"
    fi
done

while true; do
    read -p "$(echo -e "${YELLOW}Enter the remote user (default is 'root'): ${NC}")" REMOTE_USER
    if [[ -z "$REMOTE_USER" ]]; then
        REMOTE_USER="root"
        echo -e "${YELLOW}No user entered. Using default user: $REMOTE_USER${NC}"
        break
    elif [[ "$REMOTE_USER" =~ ^[a-zA-Z0-9_]+$ ]]; then
        break
    else
        echo -e "${RED}Invalid username. Please enter a valid remote user name.${NC}"
    fi
done

SSH_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no $REMOTE_USER@$HOST"

if ! $SSH_CMD exit &> /dev/null; then
    echo -e "${RED}SSH connection to $HOST failed. Please check your SSH key and remote host access.${NC}"
    exit 1
fi

if ! rsync -e "ssh -i $SSH_KEY" --dry-run "$HOST":/tmp/ /tmp/ &> /dev/null; then
    echo -e "${RED}Rsync connection to $HOST failed. Please check that rsync is installed on both hosts.${NC}"
    exit 1
fi

if ! $SSH_CMD "command -v docker" &> /dev/null; then
    echo -e "${RED}Docker is not installed on the remote host $HOST. Please install Docker first.${NC}"
    exit 1
fi

echo -e "${BLUE}Listing Docker volumes on remote host $HOST...${NC}"

REMOTE_VOLUME_LIST_OUTPUT=$($SSH_CMD "docker volume ls --format '{{.Name}}'")

readarray -t VOLUME_NAMES <<< "$REMOTE_VOLUME_LIST_OUTPUT"

if [ ${#VOLUME_NAMES[@]} -eq 0 ]; then
    echo -e "${YELLOW}No Docker volumes found on remote host $HOST.${NC}"
    exit 0
fi

echo -e "${GREEN}Available Docker volumes on $HOST:${NC}"

for i in "${!VOLUME_NAMES[@]}"; do
    echo -e "$((i+1)). ${BLUE}${VOLUME_NAMES[$i]}${NC}"
done

while true; do
    read -p "$(echo -e "${YELLOW}Enter the number of the Docker volume you want to select: ${NC}")" choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#VOLUME_NAMES[@]}" ]; then
        SELECTED_VOLUME=${VOLUME_NAMES[$((choice-1))]}
        echo -e "${GREEN}You have selected: ${BLUE}$SELECTED_VOLUME${NC}"
        break
    else
        echo -e "${RED}Invalid input. Please enter a number between 1 and ${#VOLUME_NAMES[@]}.${NC}"
    fi
done

REMOTE_BACKUP_DIR="/tmp/backup"
execute_command "$SSH_CMD \"mkdir -p $REMOTE_BACKUP_DIR\""
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to create remote backup directory: $REMOTE_BACKUP_DIR${NC}"
    exit 1
fi

LOCAL_BACKUP_DIR="/tmp/backup"
execute_command "mkdir -p \"$LOCAL_BACKUP_DIR\""
if [ ! -d "$LOCAL_BACKUP_DIR" ]; then
    echo -e "${RED}Failed to create local backup directory: $LOCAL_BACKUP_DIR${NC}"
    exit 1
fi

BACKUP_FILE="$SELECTED_VOLUME-backup.tar"

echo -e "${BLUE}Attempting to backup Docker volume $SELECTED_VOLUME on the remote host...${NC}"
execute_command "$SSH_CMD \"docker run --rm -v $SELECTED_VOLUME:/source -v $REMOTE_BACKUP_DIR:/backup ubuntu tar cvf /backup/$BACKUP_FILE -C /source .\""


echo -e "${BLUE}Attempting to transfer backup to localhost...${NC}"
execute_command "rsync -avz -e \"ssh -i $SSH_KEY\" \"$REMOTE_USER@$HOST:$REMOTE_BACKUP_DIR/$BACKUP_FILE\" \"$LOCAL_BACKUP_DIR/$BACKUP_FILE\""

echo -e "${GREEN}Backup of Docker volume $SELECTED_VOLUME created and transferred to localhost: $LOCAL_BACKUP_DIR/$BACKUP_FILE${NC}"


echo -e "${BLUE}Attempting to restore Docker volume $SELECTED_VOLUME on localhost...${NC}"

execute_command "docker volume create $SELECTED_VOLUME"

execute_command "docker run --rm -v $LOCAL_BACKUP_DIR/$BACKUP_FILE:/backup.tar -v $SELECTED_VOLUME:/target ubuntu sh -c 'tar xvf /backup.tar -C /target'"

echo -e "${GREEN}Docker volume $SELECTED_VOLUME restored successfully on localhost.${NC}"
