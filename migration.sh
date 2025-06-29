#!/bin/bash

# Debugging log file
LOGFILE="/tmp/clp_migration_debug.log"

# Credentials log file
CREDENTIALS_FILE="/tmp/credentials.log"

# Step 1: Pre-filled SSH details for the remote CloudPanel server
ssh_user="<SSH_USER>"
ssh_host="<SSH_HOST>"
ssh_pass="<SSH_PASSWORD>"

# Step 2: Path to the SQLite database on the remote server and local paths
remote_db_path="/home/clp/htdocs/app/data/db.sq3"
local_copy_path="/tmp/db_remote_copy.sq3"  # Temporary copy of the remote DB
local_db_path="/home/clp/htdocs/app/data/db.sq3"  # Local CloudPanel DB path

# Step 3: Check if required commands are installed, if not, install them
if ! command -v sshpass &> /dev/null; then
    echo "sshpass is not installed. Installing sshpass..." | tee -a "$LOGFILE"
    sudo apt-get update
    sudo apt-get install -y sshpass
fi

if ! command -v sqlite3 &> /dev/null; then
    echo "sqlite3 is not installed. Installing sqlite3..." | tee -a "$LOGFILE"
    sudo apt-get update
    sudo apt-get install -y sqlite3
fi

if ! command -v rsync &> /dev/null; then
    echo "rsync is not installed. Installing rsync..." | tee -a "$LOGFILE"
    sudo apt-get update
    sudo apt-get install -y rsync
fi

if ! command -v openssl &> /dev/null; then
    echo "openssl is not installed. Installing openssl..." | tee -a "$LOGFILE"
    sudo apt-get update
    sudo apt-get install -y openssl
fi

# Step 4: Connect to the remote server and copy the SQLite database
echo "Connecting to the remote server and copying the database file..." | tee -a "$LOGFILE"
sshpass -p "$ssh_pass" scp "$ssh_user@$ssh_host:$remote_db_path" "$local_copy_path"

if [ $? -eq 0 ]; then
    echo "Database file copied successfully to $local_copy_path." | tee -a "$LOGFILE"
else
    echo "Failed to copy the database file. Please check the SSH details or remote server." | tee -a "$LOGFILE"
    exit 1
fi

# Step 5: List all PHP sites present in the remote database
echo "Listing all PHP sites present in the remote database..." | tee -a "$LOGFILE"

php_sites=$(sqlite3 "$local_copy_path" "
SELECT s.id, s.domain_name, s.user, s.user_password, p.php_version
FROM site s
JOIN php_settings p ON s.id = p.site_id
WHERE s.type = 'php';")

if [ -z "$php_sites" ]; then
    echo "No PHP sites found in the database." | tee -a "$LOGFILE"
    exit 1
fi

# Step 6: Iterate through the PHP sites
while IFS="|" read -r site_id domain_name site_user site_password php_version; do
    echo "Processing site_id: $site_id, domain_name: $domain_name" | tee -a "$LOGFILE"

    # Fallback for empty fields
    [ -z "$php_version" ] && php_version="7.4"  # Default PHP version if not specified
    [ -z "$site_user" ] && site_user="defaultuser"  # Default user if not specified
    [ -z "$site_password" ] && site_password="defaultpassword"  # Default password if not specified

    # Step 7: Create the PHP site using clpctl
    echo "Creating site: $domain_name with PHP version: $php_version" | tee -a "$LOGFILE"
    clpctl site:add:php --domainName="$domain_name" --phpVersion="$php_version" --vhostTemplate="Generic" --siteUser="$site_user" --siteUserPassword="$site_password" 2>&1 | tee -a "$LOGFILE"

    if [ $? -eq 0 ]; then
        echo "Site $domain_name created successfully." | tee -a "$LOGFILE"

        # Retrieve the local site_id based on domain_name
        local_site_id=$(sqlite3 "$local_db_path" "SELECT id FROM site WHERE domain_name = '$domain_name';")
        echo "Local site_id for $domain_name is $local_site_id." | tee -a "$LOGFILE"

        # Step 8: Extract vhost_template from the remote SQLite database
        echo "Extracting vhost_template for $domain_name..." | tee -a "$LOGFILE"
        vhost_template=$(sqlite3 "$local_copy_path" "
SELECT vhost_template
FROM site
WHERE domain_name = '$domain_name';")

        # Ensure multi-line and special characters are handled
        if [ -z "$vhost_template" ]; then
            echo "No valid vhost_template found for $domain_name, skipping update." | tee -a "$LOGFILE"
        else
            echo "Updating the local SQLite database with the vhost_template for $domain_name..." | tee -a "$LOGFILE"

            # Escape single quotes for proper SQL formatting
            cleaned_vhost_template=$(echo "$vhost_template" | sed "s/'/''/g")

            # Step 9: Update the local CloudPanel SQLite database with the vhost_template
            sqlite3 "$local_db_path" "UPDATE site SET vhost_template = '$cleaned_vhost_template' WHERE domain_name = '$domain_name';"

            if [ $? -eq 0 ]; then
                echo "Local SQLite database updated with vhost_template for $domain_name." | tee -a "$LOGFILE"
            else
                echo "Failed to update the local SQLite database for $domain_name." | tee -a "$LOGFILE"
            fi
        fi

        # Step 9a: Update 'application' and 'varnish_cache' fields
        echo "Fetching 'application' and 'varnish_cache' from remote database for $domain_name..." | tee -a "$LOGFILE"
        app_varnish=$(sqlite3 "$local_copy_path" "
SELECT application || '|' || varnish_cache
FROM site
WHERE domain_name = '$domain_name';")
        IFS="|" read -r application varnish_cache <<< "$app_varnish"

        # Check if values are not empty
        if [ -n "$application" ] || [ -n "$varnish_cache" ]; then
            escaped_application=$(echo "$application" | sed "s/'/''/g")
            [ -z "$escaped_application" ] && application="NULL" || application="'$escaped_application'"
            [ -z "$varnish_cache" ] && varnish_cache="NULL"

            echo "Updating local database with application=$application and varnish_cache=$varnish_cache for $domain_name..." | tee -a "$LOGFILE"

            # Update the local database
            sqlite3 "$local_db_path" "UPDATE site SET application = $application, varnish_cache = $varnish_cache WHERE id = $local_site_id;"

            if [ $? -eq 0 ]; then
                echo "Successfully updated 'application' and 'varnish_cache' for $domain_name in local database." | tee -a "$LOGFILE"
            else
                echo "Failed to update 'application' and 'varnish_cache' for $domain_name in local database." | tee -a "$LOGFILE"
            fi
        else
            echo "No 'application' or 'varnish_cache' values found for $domain_name in remote database." | tee -a "$LOGFILE"
        fi

        # Step 10: Copy the Nginx configuration from the remote server
        echo "Copying Nginx configuration for $domain_name..." | tee -a "$LOGFILE"
        remote_nginx_conf="/etc/nginx/sites-enabled/$domain_name.conf"
        local_nginx_conf="/etc/nginx/sites-enabled/$domain_name.conf"

        sshpass -p "$ssh_pass" scp "$ssh_user@$ssh_host:$remote_nginx_conf" "$local_nginx_conf"

        if [ $? -eq 0 ]; then
            echo "Nginx configuration copied successfully for $domain_name." | tee -a "$LOGFILE"
        else
            echo "Failed to copy Nginx configuration for $domain_name." | tee -a "$LOGFILE"
        fi

        # Step 11: Copy SSL certificate files from the remote server
        echo "Copying SSL certificate files for $domain_name..." | tee -a "$LOGFILE"
        remote_ssl_cert_dir="/etc/nginx/ssl-certificates/"
        local_ssl_cert_dir="/etc/nginx/ssl-certificates/"

        sshpass -p "$ssh_pass" rsync -avz --progress "$ssh_user@$ssh_host:$remote_ssl_cert_dir" "$local_ssl_cert_dir"

        if [ $? -eq 0 ]; then
            echo "SSL certificate files copied successfully for $domain_name." | tee -a "$LOGFILE"
        else
            echo "Failed to copy SSL certificate files for $domain_name." | tee -a "$LOGFILE"
        fi

        # Step 21a: Rsync site content from remote server to local server
        echo "Rsyncing the site content from remote to local for $domain_name..." | tee -a "$LOGFILE"
        remote_site_dir="/home/$site_user/htdocs/$domain_name/"
        local_site_dir="/home/$site_user/htdocs/$domain_name/"

        # Create the local directory if it does not exist
        if [ ! -d "$local_site_dir" ]; then
            echo "Creating directory $local_site_dir" | tee -a "$LOGFILE"
            mkdir -p "$local_site_dir"
            chown "$site_user:$site_user" "$local_site_dir"  # Ensure correct ownership
        fi

        # Rsync the site content from remote to local
        sshpass -p "$ssh_pass" rsync -avz --progress "$ssh_user@$ssh_host:$remote_site_dir" "$local_site_dir"

        if [ $? -eq 0 ]; then
            echo "Site content for $domain_name copied successfully." | tee -a "$LOGFILE"
        else
            echo "Failed to copy site content for $domain_name." | tee -a "$LOGFILE"
        fi

        # Step 12: Fetch FTP users for the site from the remote database
ftp_users=$(sqlite3 "$local_copy_path" "
SELECT user_name, home_directory
FROM ftp_user
WHERE site_id = $site_id;")

if [ ! -z "$ftp_users" ]; then
    echo "$ftp_users" | while IFS="|" read -r ftp_user_name ftp_home_directory; do
        ftp_password=$(openssl rand -base64 12)

        echo "Creating FTP user $ftp_user_name for $domain_name with home directory $ftp_home_directory..." | tee -a "$LOGFILE"
        
        # Create the system user and set their home directory
        adduser --disabled-password --home "$ftp_home_directory" --gecos "" "$ftp_user_name"
        echo "$ftp_user_name:$ftp_password" | chpasswd

        mkdir -p "$ftp_home_directory"
        chown "$site_user:$site_user" "$ftp_home_directory"

        # Add FTP user to both the site user's group and ftp-user group
        usermod -aG "$site_user" "$ftp_user_name"
        usermod -aG ftp-user "$ftp_user_name"

        echo "FTP user $ftp_user_name created and added to $site_user and ftp-user groups with home directory $ftp_home_directory." | tee -a "$LOGFILE"
        echo "FTP User: $ftp_user_name, FTP Password: $ftp_password, Home Directory: $ftp_home_directory" | tee -a "$CREDENTIALS_FILE"

        # Step 12a: Insert FTP user into local CloudPanel SQLite database using local_site_id
        current_time=$(date '+%Y-%m-%d %H:%M:%S')

        escaped_ftp_user_name=$(echo "$ftp_user_name" | sed "s/'/''/g")
        escaped_ftp_home_directory=$(echo "$ftp_home_directory" | sed "s/'/''/g")

        sqlite3 "$local_db_path" "INSERT INTO ftp_user (site_id, created_at, updated_at, user_name, home_directory) 
        VALUES ($local_site_id, '$current_time', '$current_time', '$escaped_ftp_user_name', '$escaped_ftp_home_directory');"

        if [ $? -eq 0 ]; then
            echo "FTP user $ftp_user_name inserted into local CloudPanel database for $domain_name." | tee -a "$LOGFILE"
        else
            echo "Failed to insert FTP user $ftp_user_name into local CloudPanel database for $domain_name." | tee -a "$LOGFILE"
        fi

    done

    # Restart ProFTPD after creating all FTP users
    echo "Restarting ProFTPD service..." | tee -a "$LOGFILE"
    sudo systemctl restart proftpd

    if [ $? -eq 0 ]; then
        echo "ProFTPD service restarted successfully." | tee -a "$LOGFILE"
    else
        echo "Failed to restart ProFTPD service." | tee -a "$LOGFILE"
    fi

else
    echo "No FTP users found for $domain_name, skipping FTP setup." | tee -a "$LOGFILE"
fi

        # Step 13: Fetch and add cron jobs
        cron_jobs=$(sqlite3 "$local_copy_path" "
        SELECT c.minute, c.hour, c.day, c.month, c.weekday, c.command
        FROM cron_job c
        WHERE c.site_id = $site_id;")

        if [ ! -z "$cron_jobs" ]; then
            cron_file="/etc/cron.d/$site_user"
            echo "$cron_jobs" | while IFS="|" read -r minute hour day month weekday command; do
                echo "$minute $hour $day $month $weekday $command" >> "$cron_file"
                current_time=$(date '+%Y-%m-%d %H:%M:%S')
                escaped_minute=$(echo "$minute" | sed "s/'/''/g")
                escaped_hour=$(echo "$hour" | sed "s/'/''/g")
                escaped_day=$(echo "$day" | sed "s/'/''/g")
                escaped_month=$(echo "$month" | sed "s/'/''/g")
                escaped_weekday=$(echo "$weekday" | sed "s/'/''/g")
                escaped_command=$(echo "$command" | sed "s/'/''/g")

                sqlite3 "$local_db_path" "INSERT INTO cron_job (site_id, created_at, updated_at, minute, hour, day, month, weekday, command) VALUES ($local_site_id, '$current_time', '$current_time', '$escaped_minute', '$escaped_hour', '$escaped_day', '$escaped_month', '$escaped_weekday', '$escaped_command');"

                if [ $? -eq 0 ]; then
                    echo "Cron job inserted into local CloudPanel database for $domain_name." | tee -a "$LOGFILE"
                else
                    echo "Failed to insert cron job into local CloudPanel database for $domain_name." | tee -a "$LOGFILE"
                fi
            done
            chmod 644 "$cron_file"
            echo "Cron jobs added for $site_user in $cron_file." | tee -a "$LOGFILE"
        else
            echo "No cron jobs found for $domain_name." | tee -a "$LOGFILE"
        fi

    else
        echo "Failed to create site $domain_name. Skipping to the next site." | tee -a "$LOGFILE"
        continue
    fi

    echo "--------------------------------------" | tee -a "$LOGFILE"

done < <(echo "$php_sites")

# After setting up PHP sites, proceed with MySQL dump operations

# Step 14: List all PHP sites with MySQL databases from the remote database
echo "Listing all PHP sites with MySQL databases from the remote database..." | tee -a "$LOGFILE"

php_sites_mysql=$(sqlite3 "$local_copy_path" "
SELECT s.id, s.domain_name, s.user, d.name AS db_name, du.user_name AS db_user
FROM site s
JOIN database d ON s.id = d.site_id
JOIN database_user du ON d.id = du.database_id
WHERE s.type = 'php';")

# Debugging: List out all the sites fetched
echo "Fetched PHP Sites with MySQL Databases:" | tee -a "$LOGFILE"
echo "$php_sites_mysql" | tee -a "$LOGFILE"

if [ -z "$php_sites_mysql" ]; then
    echo "No PHP sites with MySQL databases found in the database." | tee -a "$LOGFILE"
    exit 1
fi

# Step 15: Iterate through the PHP sites with MySQL and perform database operations
echo "Starting MySQL dump, database creation, and import for each site..." | tee -a "$LOGFILE"

while IFS="|" read -r site_id domain_name site_user db_name db_user; do
    echo "Processing site: $domain_name with DB name: $db_name and DB user: $db_user" | tee -a "$LOGFILE"

    remote_backup_dir="/home/$site_user/backups"
    remote_sql_file="${remote_backup_dir}/${db_name}.sql.gz"

    # Step 16: Dump the MySQL database using clpctl in the background
    echo "Dumping the MySQL database for $domain_name using clpctl db:export..." | tee -a "$LOGFILE"
   # sshpass -p "$ssh_pass" ssh "$ssh_user@$ssh_host" "mkdir -p '$remote_backup_dir' && clpctl db:export --databaseName='$db_name' --file='$remote_sql_file'" &

   sshpass -p "$ssh_pass" ssh -n "$ssh_user@$ssh_host" \
  "mkdir -p '$remote_backup_dir' && clpctl db:export --databaseName='$db_name' --file='$remote_sql_file'"

    if [ $? -eq 0 ]; then
        echo "Database $db_name export initiated in the background." | tee -a "$LOGFILE"
    else
        echo "Failed to initiate export for database $db_name for $domain_name. Skipping..." | tee -a "$LOGFILE"
        continue  # Skip to the next site if the dump fails
    fi

    # Step 17: Copy the compressed MySQL dump from remote to local in background
    echo "Copying the MySQL dump from remote to local server for $domain_name..." | tee -a "$LOGFILE"
   # sshpass -p "$ssh_pass" scp "$ssh_user@$ssh_host:$remote_sql_file" "/tmp/${db_name}.sql.gz" &
   sshpass -p "$ssh_pass" scp < /dev/null "$ssh_user@$ssh_host:$remote_sql_file" "/tmp/${db_name}.sql.gz"
   
    if [ $? -eq 0 ]; then
        echo "MySQL dump copy initiated in the background for $domain_name." | tee -a "$LOGFILE"
    else
        echo "Failed to initiate copy for MySQL dump for $domain_name." | tee -a "$LOGFILE"
    fi

    echo "Finished initiating MySQL dump and copy for site: $domain_name" | tee -a "$LOGFILE"
    echo "--------------------------------------" | tee -a "$LOGFILE"

done < <(echo "$php_sites_mysql")

# Wait for all background jobs to complete before proceeding
wait

# Step 18: Create databases and import dumps
echo "Creating databases and importing dumps..." | tee -a "$LOGFILE"

while IFS="|" read -r site_id domain_name site_user db_name db_user; do
    echo "Setting up database for site: $domain_name" | tee -a "$LOGFILE"

    # Generate a random password for the database user
    db_password=$(openssl rand -base64 12)

    # Step 19: Create the database using clpctl db:add
    echo "Creating database $db_name for domain $domain_name..." | tee -a "$LOGFILE"
    clpctl db:add --domainName="$domain_name" --databaseName="$db_name" --databaseUserName="$db_user" --databaseUserPassword="$db_password" 2>&1 | tee -a "$LOGFILE"

    if [ $? -eq 0 ]; then
        echo "Database $db_name created successfully for site $domain_name." | tee -a "$LOGFILE"
        echo "Database User: $db_user" | tee -a "$LOGFILE"
        echo "Database Password: $db_password" | tee -a "$LOGFILE"

        # Log database credentials
        echo "Database credentials for $domain_name:" | tee -a "$CREDENTIALS_FILE"
        echo "Database Name: $db_name, Database User: $db_user, Database Password: $db_password" | tee -a "$CREDENTIALS_FILE"
    else
        echo "Failed to create database $db_name for site $domain_name." | tee -a "$LOGFILE"
        continue
    fi

    # Step 20: Import the database dump
    local_sql_file="/tmp/${db_name}.sql.gz"

    if [ -f "$local_sql_file" ]; then
        echo "Importing database dump for $db_name..." | tee -a "$LOGFILE"
        clpctl db:import --databaseName="$db_name" --file="$local_sql_file" 2>&1 | tee -a "$LOGFILE"

        if [ $? -eq 0 ]; then
            echo "Database dump imported successfully for $db_name." | tee -a "$LOGFILE"
        else
            echo "Failed to import database dump for $db_name." | tee -a "$LOGFILE"
        fi
    else
        echo "Database dump file $local_sql_file not found for $db_name." | tee -a "$LOGFILE"
    fi

    echo "Finished setting up database for site: $domain_name" | tee -a "$LOGFILE"
    echo "--------------------------------------" | tee -a "$LOGFILE"

done < <(echo "$php_sites_mysql")

# Step 22: Completion message
echo "Database setup, FTP user creation, site content copy, and import process completed." | tee -a "$LOGFILE"
