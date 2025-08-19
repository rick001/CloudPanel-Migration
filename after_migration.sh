#!/bin/bash

# Script to update WordPress and Laravel database credentials after CloudPanel migration
# and optionally generate Let's Encrypt SSL certificates

# Log file paths
CREDENTIALS_FILE="/tmp/credentials.log"
UPDATE_LOG="/tmp/credential_update.log"
SSL_LOG="/tmp/ssl_generation.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$UPDATE_LOG"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$UPDATE_LOG"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$UPDATE_LOG"
}

# Function to detect application type
detect_app_type() {
    local site_path=$1
    
    # Debug: show what we're checking
    print_status "Checking for app type in: $site_path" >&2
    
    if [ -f "$site_path/wp-config.php" ]; then
        echo "wordpress"
    elif [ -f "$site_path/.env" ]; then
        # Check for Laravel indicators - be more flexible
        if [ -f "$site_path/artisan" ] || [ -d "$site_path/vendor" ] || [ -f "$site_path/composer.json" ]; then
            echo "laravel"
        # Check if .env contains Laravel-specific settings
        elif grep -q "APP_NAME\|APP_ENV\|APP_KEY" "$site_path/.env" 2>/dev/null; then
            echo "laravel"
        else
            echo "unknown"
        fi
    # Check for .env in public subdirectory (common Laravel setup)
    elif [ -f "$site_path/public/.env" ]; then
        print_status "Found .env in public subdirectory" >&2
        if [ -f "$site_path/artisan" ] || [ -d "$site_path/vendor" ] || [ -f "$site_path/composer.json" ]; then
            print_status "Found Laravel indicators in main directory with .env in public/" >&2
            echo "laravel:$site_path:public"
        elif grep -q "APP_NAME\|APP_ENV\|APP_KEY" "$site_path/public/.env" 2>/dev/null; then
            print_status "Found Laravel env vars in public/.env" >&2
            echo "laravel:$site_path:public"
        else
            echo "unknown"
        fi
    else
        echo "unknown"
    fi
}

# Function to find site directory
find_site_directory() {
    local domain=$1
    
    # First, try to get the actual site user from CloudPanel database
    local site_user=$(sqlite3 /home/clp/htdocs/app/data/db.sq3 "SELECT user FROM site WHERE domain_name = '$domain';" 2>/dev/null)
    
    if [ -z "$site_user" ]; then
        print_warning "Could not find site user in database for $domain, trying common patterns" >&2
        
        # Try different patterns for the username
        # Pattern 1: domain without TLD (e.g., coulterpeterson for coulterpeterson.com)
        site_user=$(echo "$domain" | cut -d. -f1)
        
        # Check if this user exists
        if [ ! -d "/home/$site_user" ]; then
            # Pattern 2: full domain with dots replaced by dashes
            site_user="${domain//./-}"
            
            if [ ! -d "/home/$site_user" ]; then
                # Pattern 3: full domain with dots replaced by underscores
                site_user="${domain//./_}"
            fi
        fi
    fi
    
    print_status "Checking for site user: $site_user" >&2
    
    # The standard CloudPanel structure is /home/{user}/htdocs/{full-domain}
    # So for coulterpeterson.com, it would be /home/coulterpeterson/htdocs/coulterpeterson.com
    local primary_path="/home/$site_user/htdocs/$domain"
    
    if [ -d "$primary_path" ]; then
        print_status "Found site at standard location: $primary_path" >&2
        echo "$primary_path"
        return 0
    fi
    
    # Try alternative paths
    local site_paths=(
        "/home/$site_user/htdocs/www.$domain"
        "/home/$site_user/htdocs"
        "/home/${domain//./-}/htdocs/$domain"
        "/home/${domain//./_}/htdocs/$domain"
    )
    
    for site_path in "${site_paths[@]}"; do
        if [ -d "$site_path" ]; then
            print_status "Found site at: $site_path" >&2
            echo "$site_path"
            return 0
        fi
    done
    
    # If still not found, try to find any directory containing the domain
    print_warning "Standard paths not found, searching for domain directory..." >&2
    local found_path=$(find /home -type d -name "$domain" 2>/dev/null | head -1)
    if [ -n "$found_path" ]; then
        print_status "Found site at: $found_path" >&2
        echo "$found_path"
        return 0
    fi
    
    return 1
}

# Function to update WordPress credentials
update_wordpress_credentials() {
    local wp_config_path=$1
    local db_name=$2
    local db_user=$3
    local db_password=$4
    local domain=$5
    
    print_status "Updating WordPress credentials for $domain"
    
    # Backup the original wp-config.php
    cp "$wp_config_path" "${wp_config_path}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Update database name
    sed -i "s/define\s*(\s*['\"]DB_NAME['\"]\s*,\s*['\"][^'\"]*['\"]\s*)/define('DB_NAME', '$db_name')/" "$wp_config_path"
    
    # Update database user
    sed -i "s/define\s*(\s*['\"]DB_USER['\"]\s*,\s*['\"][^'\"]*['\"]\s*)/define('DB_USER', '$db_user')/" "$wp_config_path"
    
    # Update database password - handle special characters properly
    # Use sed with different delimiter to avoid escaping issues
    sed -i "s|define\s*(\s*['\"]DB_PASSWORD['\"]\s*,\s*['\"][^'\"]*['\"]\s*)|define('DB_PASSWORD', '$db_password')|" "$wp_config_path"
    
    # Update database host if needed (usually localhost for CloudPanel)
    sed -i "s/define\s*(\s*['\"]DB_HOST['\"]\s*,\s*['\"][^'\"]*['\"]\s*)/define('DB_HOST', 'localhost')/" "$wp_config_path"
    
    print_status "WordPress credentials updated for $domain"
}

# Function to update Laravel credentials
update_laravel_credentials() {
    local env_path=$1
    local db_name=$2
    local db_user=$3
    local db_password=$4
    local domain=$5
    
    print_status "Updating Laravel credentials for $domain"
    
    # Backup the original .env file
    cp "$env_path" "${env_path}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Update database credentials in .env file
    # Handle special characters in password
    escaped_password=$(printf '%s\n' "$db_password" | sed 's/[[\.*^$()+?{|]/\\&/g')
    
    # Update DB_DATABASE
    sed -i "s/^DB_DATABASE=.*/DB_DATABASE=$db_name/" "$env_path"
    
    # Update DB_USERNAME
    sed -i "s/^DB_USERNAME=.*/DB_USERNAME=$db_user/" "$env_path"
    
    # Update DB_PASSWORD (handle passwords with special characters)
    sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$escaped_password/" "$env_path"
    
    # Update DB_HOST if needed
    sed -i "s/^DB_HOST=.*/DB_HOST=localhost/" "$env_path"
    
    # Clear Laravel cache
    local site_dir=$(dirname "$env_path")
    if [ -f "$site_dir/artisan" ]; then
        print_status "Clearing Laravel cache for $domain"
        cd "$site_dir"
        php artisan config:clear 2>/dev/null
        php artisan cache:clear 2>/dev/null
    fi
    
    print_status "Laravel credentials updated for $domain"
}

# Function to generate Let's Encrypt SSL certificate
generate_ssl_certificate() {
    local domain=$1
    local generate_ssl=$2
    
    if [ "$generate_ssl" != "yes" ]; then
        return 1
    fi
    
    print_status "Generating Let's Encrypt SSL certificate for $domain" | tee -a "$SSL_LOG"
    
    # Capture output to analyze for actual success/failure
    local ssl_output=$(clpctl lets-encrypt:install:certificate --domainName="$domain" 2>&1)
    local result=$?
    
    # Log the output
    echo "$ssl_output" | tee -a "$SSL_LOG"
    
    # Check for success indicators in output, not just exit code
    if [[ "$ssl_output" == *"Certificate installation was successful"* ]]; then
        print_status "SSL certificate generated successfully for $domain" | tee -a "$SSL_LOG"
        return 0
    elif [[ "$ssl_output" == *"Domain could not be validated"* ]] || [[ "$ssl_output" == *"error"* ]]; then
        print_error "Failed to generate SSL certificate for $domain" | tee -a "$SSL_LOG"
        if [[ "$ssl_output" == *"DNS problem"* ]]; then
            print_warning "DNS issue detected - domain may not be pointing to this server yet" | tee -a "$SSL_LOG"
        elif [[ "$ssl_output" == *"Invalid response"* ]]; then
            print_warning "HTTP validation failed - check web server configuration" | tee -a "$SSL_LOG"
        fi
        print_warning "You can manually retry: clpctl lets-encrypt:install:certificate --domainName=\"$domain\"" | tee -a "$SSL_LOG"
        return 1
    else
        print_status "SSL certificate generated successfully for $domain" | tee -a "$SSL_LOG"
        return 0
    fi
}

# Function to list all sites in CloudPanel
list_cloudpanel_sites() {
    print_status "Listing all sites in CloudPanel database:"
    sqlite3 /home/clp/htdocs/app/data/db.sq3 "SELECT domain_name, user, type FROM site;" 2>/dev/null | while IFS='|' read -r domain user type; do
        print_status "  Domain: $domain, User: $user, Type: $type"
        # Also check if the directory exists
        if [ -d "/home/$user/htdocs/$domain" ]; then
            print_status "    ✓ Directory exists: /home/$user/htdocs/$domain"
        else
            print_warning "    ✗ Directory not found at expected location: /home/$user/htdocs/$domain"
        fi
    done
}

# Main script execution
main() {
    echo "========================================" | tee -a "$UPDATE_LOG"
    echo "Starting credential update process at $(date)" | tee -a "$UPDATE_LOG"
    echo "========================================" | tee -a "$UPDATE_LOG"
    
    # Check if credentials file exists
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        print_error "Credentials file not found at $CREDENTIALS_FILE"
        exit 1
    fi
    
    # List all sites for debugging
    list_cloudpanel_sites
    echo "----------------------------------------" | tee -a "$UPDATE_LOG"
    
    # Ask user if they want to generate SSL certificates
    read -p "Do you want to generate Let's Encrypt SSL certificates for all sites? (yes/no): " generate_ssl
    
    # Counter for statistics
    local success_count=0
    local fail_count=0
    local ssl_success=0
    local ssl_fail=0
    
    # Parse credentials file and update configurations
    while IFS= read -r line; do
        # Look for database credential lines
        if [[ $line == "Database credentials for "* ]]; then
            # Extract domain name
            domain=$(echo "$line" | sed 's/Database credentials for \(.*\):/\1/')
            
            # Read the next line with actual credentials
            read -r cred_line
            
            # Extract credentials using more robust parsing
            db_name=$(echo "$cred_line" | grep -oP 'Database Name: \K[^,]+' | xargs)
            db_user=$(echo "$cred_line" | grep -oP 'Database User: \K[^,]+' | xargs)
            db_password=$(echo "$cred_line" | grep -oP 'Database Password: \K.*' | xargs)
            
            print_status "Processing domain: $domain"
            print_status "Database: $db_name, User: $db_user"
            
            # Find the site directory
            site_path=$(find_site_directory "$domain")
            
            if [ $? -eq 0 ] && [ -n "$site_path" ]; then
                # Clean the path in case it has any extra output
                site_path=$(echo "$site_path" | tail -1 | tr -d '\n')
                print_status "Found site directory: $site_path"
                
                # Detect application type
                app_type=$(detect_app_type "$site_path")
                
                case $app_type in
                    wordpress)
                        if [ -f "$site_path/wp-config.php" ]; then
                            update_wordpress_credentials "$site_path/wp-config.php" "$db_name" "$db_user" "$db_password" "$domain"
                            ((success_count++))
                        else
                            print_error "wp-config.php not found for $domain at $site_path"
                            ((fail_count++))
                        fi
                        ;;
                    laravel)
                        if [ -f "$site_path/.env" ]; then
                            update_laravel_credentials "$site_path/.env" "$db_name" "$db_user" "$db_password" "$domain"
                            ((success_count++))
                        else
                            print_error ".env file not found for Laravel site $domain at $site_path"
                            ((fail_count++))
                        fi
                        ;;
                    laravel:*:public)
                        # Laravel app with .env in public subdirectory
                        laravel_path="${app_type#laravel:}"
                        laravel_path="${laravel_path%:public}"
                        print_status "Detected Laravel app with .env in public subdirectory: $laravel_path/public/"
                        if [ -f "$laravel_path/public/.env" ]; then
                            update_laravel_credentials "$laravel_path/public/.env" "$db_name" "$db_user" "$db_password" "$domain"
                            ((success_count++))
                        else
                            print_error ".env file not found for Laravel site $domain at $laravel_path/public/"
                            ((fail_count++))
                        fi
                        ;;
                    laravel:*)
                        # Laravel app with .env in parent directory
                        laravel_path="${app_type#laravel:}"
                        print_status "Detected Laravel app with files in parent directory: $laravel_path"
                        if [ -f "$laravel_path/.env" ]; then
                            update_laravel_credentials "$laravel_path/.env" "$db_name" "$db_user" "$db_password" "$domain"
                            ((success_count++))
                        else
                            print_error ".env file not found for Laravel site $domain at $laravel_path"
                            ((fail_count++))
                        fi
                        ;;
                    *)
                        print_warning "Unknown application type for $domain - analyzing directory contents"
                        print_status "Looking for configuration files in: $site_path"
                        if [ -d "$site_path" ]; then
                            # Check for common config files and suggest action
                            config_files=$(ls -la "$site_path" 2>/dev/null | grep -E "(config|\.env|wp-config|composer\.json|package\.json)" | head -5)
                            if [ -n "$config_files" ]; then
                                echo "$config_files"
                                if [ -f "$site_path/index.html" ]; then
                                    print_status "Appears to be a static HTML site - no database credentials needed"
                                elif [ -f "$site_path/composer.json" ]; then
                                    print_warning "Possible PHP application - manual configuration may be needed"
                                elif [ -f "$site_path/package.json" ]; then
                                    print_warning "Possible Node.js application - manual configuration may be needed"
                                else
                                    print_warning "Manual credential update required for this application type"
                                fi
                            else
                                print_warning "No common configuration files found"
                            fi
                        fi
                        ((fail_count++))
                        ;;
                esac
            else
                print_error "Could not find site directory for $domain"
                ((fail_count++))
            fi
            
            # Generate SSL certificate if requested
            if [ "$generate_ssl" = "yes" ]; then
                generate_ssl_certificate "$domain" "$generate_ssl"
                ssl_result=$?
                if [ $ssl_result -eq 0 ]; then
                    ((ssl_success++))
                else
                    ((ssl_fail++))
                fi
            fi
            
            echo "----------------------------------------" | tee -a "$UPDATE_LOG"
        fi
    done < "$CREDENTIALS_FILE"
    
    # Final summary
    echo "========================================" | tee -a "$UPDATE_LOG"
    echo "Credential update process completed at $(date)" | tee -a "$UPDATE_LOG"
    echo "========================================" | tee -a "$UPDATE_LOG"
    
    print_status "Summary:"
    print_status "  - Credentials updated successfully: $success_count"
    print_status "  - Credentials update failed: $fail_count"
    
    if [ "$generate_ssl" = "yes" ]; then
        print_status "  - SSL certificates generated: $ssl_success"
        print_status "  - SSL certificates failed: $ssl_fail"
    fi
    
    print_status "Check the following log files for details:"
    print_status "  - Credential updates: $UPDATE_LOG"
    if [ "$generate_ssl" = "yes" ]; then
        print_status "  - SSL generation: $SSL_LOG"
    fi
    
    # Restart web services to apply changes
    print_status "Restarting web services..."
    systemctl reload nginx
    systemctl reload php*-fpm
    
    print_status "All operations completed!"
    
    # Show important notes
    echo ""
    if [ "$ssl_fail" -gt 0 ] && [ "$generate_ssl" = "yes" ]; then
        print_warning "IMPORTANT: Some SSL certificates failed to generate. This is usually because:"
        print_warning "  1. The domain's DNS is not yet pointing to this server (most common)"
        print_warning "  2. Port 80 is not accessible from the internet"
        print_warning ""
        print_warning "After DNS propagation, you can manually generate SSL certificates with:"
        print_warning "  clpctl lets-encrypt:install:certificate --domainName=\"yourdomain.com\""
    fi
    
    if [ "$fail_count" -gt 0 ]; then
        print_warning ""
        print_warning "Some sites failed to update. Check $UPDATE_LOG for details."
        print_warning "You may need to manually update configuration files for these sites."
    fi
}

# Run the main function
main
