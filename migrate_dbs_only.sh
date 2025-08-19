#!/bin/bash

# Database-only migration script for CloudPanel
# Exports databases from original server and imports to new server

# Log files
LOGFILE="/tmp/db_migration.log"
CREDENTIALS_FILE="/tmp/credentials.log"

# SSH connection details for original server
ssh_user="<SSH_USER>"
ssh_host="<SSH_HOST>"
ssh_pass="<SSH_PASSWORD>"
ssh_port="<SSH_PORT>"  # Your custom SSH port

# Database paths
remote_db_path="/home/clp/htdocs/app/data/db.sq3"
local_copy_path="/tmp/db_remote_copy.sq3"
local_db_path="/home/clp/htdocs/app/data/db.sq3"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOGFILE"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOGFILE"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOGFILE"
}

# Start migration
echo "========================================" | tee -a "$LOGFILE"
echo "Starting database-only migration at $(date)" | tee -a "$LOGFILE"
echo "========================================" | tee -a "$LOGFILE"

# Check if we have the remote database copy
if [ ! -f "$local_copy_path" ]; then
    print_status "Copying remote CloudPanel database..."
    sshpass -p "$ssh_pass" scp -P "$ssh_port" "$ssh_user@$ssh_host:$remote_db_path" "$local_copy_path"
    
    if [ $? -ne 0 ]; then
        print_error "Failed to copy remote database. Check SSH credentials."
        exit 1
    fi
fi

# Get list of sites with databases from remote server
print_status "Fetching list of sites with databases from remote server..."
php_sites_mysql=$(sqlite3 "$local_copy_path" "
SELECT s.id, s.domain_name, s.user, d.name AS db_name, du.user_name AS db_user
FROM site s
JOIN database d ON s.id = d.site_id
JOIN database_user du ON d.id = du.database_id
WHERE s.type = 'php';")

if [ -z "$php_sites_mysql" ]; then
    print_error "No sites with databases found in remote server"
    exit 1
fi

print_status "Found $(echo "$php_sites_mysql" | wc -l) sites with databases to migrate"


# Export databases from remote server
print_status "Exporting databases from remote server..."
export_success=0
export_total=0

# Save to temp file to avoid subshell/pipe issues
temp_db_list="/tmp/db_list.txt"
echo "$php_sites_mysql" > "$temp_db_list"


while IFS="|" read -r site_id domain_name site_user db_name db_user; do
    echo "Processing $domain_name (DB: $db_name)..." | tee -a "$LOGFILE"
    ((export_total++))
    
    remote_backup_dir="/home/$site_user/backups"
    remote_sql_file="${remote_backup_dir}/${db_name}.sql.gz"
    local_sql_file="/tmp/${db_name}.sql.gz"
    
    # Export database on remote server
    print_status "Exporting database $db_name on remote server..."
    sshpass -p "$ssh_pass" ssh -p "$ssh_port" "$ssh_user@$ssh_host" \
        "mkdir -p '$remote_backup_dir' && clpctl db:export --databaseName='$db_name' --file='$remote_sql_file'" < /dev/null
    
    if [ $? -eq 0 ]; then
        print_status "Database $db_name exported successfully on remote server"
        
        # Copy the dump to local server
        print_status "Copying $db_name dump to local server..."
        sshpass -p "$ssh_pass" scp -P "$ssh_port" "$ssh_user@$ssh_host:$remote_sql_file" "$local_sql_file" < /dev/null
        
        if [ $? -eq 0 ]; then
            print_status "Database dump $db_name copied successfully"
            ((export_success++))
        else
            print_error "Failed to copy database dump for $db_name"
        fi
    else
        print_error "Failed to export database $db_name from remote server"
    fi
    
    echo "----------------------------------------" | tee -a "$LOGFILE"
done < "$temp_db_list"

print_status "Database export summary: $export_success/$export_total successful"
rm -f "$temp_db_list"

# Import databases to local server
print_status "Starting database import to local server..."
import_success=0
import_total=0

while IFS="|" read -r site_id domain_name site_user db_name db_user; do
    echo "Importing $domain_name (DB: $db_name)..." | tee -a "$LOGFILE"
    ((import_total++))
    
    local_sql_file="/tmp/${db_name}.sql.gz"
    
    if [ -f "$local_sql_file" ]; then
        # Check if database exists locally
        local_db_exists=$(sqlite3 "$local_db_path" "SELECT name FROM database WHERE name = '$db_name';" 2>/dev/null)
        
        if [ -z "$local_db_exists" ]; then
            print_warning "Database $db_name does not exist locally. You may need to create it first."
            print_warning "Run: clpctl db:add --domainName=\"$domain_name\" --databaseName=\"$db_name\" --databaseUserName=\"$db_user\" --databaseUserPassword=\"<password>\""
        else
            print_status "Importing database dump for $db_name..."
            clpctl db:import --databaseName="$db_name" --file="$local_sql_file" 2>&1 | tee -a "$LOGFILE"
            
            if [ $? -eq 0 ]; then
                print_status "Database $db_name imported successfully"
                ((import_success++))
                
                # Clean up the dump file
                rm -f "$local_sql_file"
            else
                print_error "Failed to import database $db_name"
            fi
        fi
    else
        print_error "Database dump file not found for $db_name at $local_sql_file"
    fi
    
    echo "----------------------------------------" | tee -a "$LOGFILE"
done < <(echo "$php_sites_mysql")

# Final summary
echo "========================================" | tee -a "$LOGFILE"
echo "Database migration completed at $(date)" | tee -a "$LOGFILE"
echo "========================================" | tee -a "$LOGFILE"

print_status "Migration Summary:"
print_status "  - Databases exported: $export_success/$export_total"
print_status "  - Databases imported: $import_success/$import_total"

if [ $import_success -lt $import_total ]; then
    print_warning "Some databases failed to import. Check the log for details."
    print_warning "You may need to manually create missing databases using clpctl db:add"
fi

print_status "Log file: $LOGFILE"
print_status "Database migration completed!"
