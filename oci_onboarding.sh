#! /bin/bash




PREFIX="ciscomcd"

usage() {
    echo "Usage: $0 [args]"
    echo "-h This help message"
    echo "-p <prefix> - Prefix to use for the App and IAM Role, defaults to ciscomcd"
    exit 1
}

while getopts "hp:w:" optname; do
    case "${optname}" in
        h)
            usage
            ;;
        p)
            PREFIX="${OPTARG}"
            ;;
    esac
done

# Function to check if a compartment is active
is_compartment_active() {
    local compartment_id=$1

    # Retrieve the lifecycle-state of the compartment
    local compartment_state=$(oci iam compartment get --compartment-id "$compartment_id" --query 'data."lifecycle-state"' --raw-output)

    # Return true (0) if the state is ACTIVE; false (1) otherwise
    [ "$compartment_state" == "ACTIVE" ]
}

# Function to wait until a compartment is active
wait_until_compartment_active() {
    local compartment_id=$1

    echo "Checking if compartment with OCID $compartment_id is active..."

    # Wait for the compartment to become active
    until is_compartment_active "$compartment_id"; do
        echo "Compartment is not active yet. Waiting..."
        sleep 10 # Wait for 10 seconds before checking again
    done

    echo "Compartment with OCID $compartment_id is now active."
}

# function to build path for compartemnt to be used in policy : example -> parent_compartment:child-compartmnet:grand-child-compartment 
build_compartment_path() {
    local compartment_id=$1
    local path=""

    # Loop to build the path up to the root compartment
    while [ "$compartment_id" != "$TENANT_ID" ]; do
        # Get the name of the compartment
        compartment_details=$(oci iam compartment get --compartment-id $compartment_id 2>/dev/null)
        compartment_name=$(echo "$compartment_details" | jq -r '.data.name')
        compartment_parent_id=$(echo "$compartment_details" | jq -r '.data."compartment-id"')

        # Break the loop if we've reached the top of the compartment hierarchy
        if [ "$compartment_parent_id" == "null" ] || [ -z "$compartment_parent_id" ]; then
            break
        fi

        # Prepend the compartment name to the path
        path="${compartment_name}${path:+:$path}"

        # Move to the parent compartment for the next iteration
        compartment_id=$compartment_parent_id
    done

    # Return the path without the root compartment
    echo "$path"
}


declare -a compartment_names

TENANT_ID=$(oci iam compartment list --all --compartment-id-in-subtree true --access-level ACCESSIBLE --include-root --raw-output --query "data[?contains(\"id\",'tenancy')].id | [0]")
USING_ROOT_COMPARTMENT=false

read -p "Do you want to enter existing Compartment id (y) or select compartments from a list (n)? [y/n] " -n 1

existing_comp=$REPLY
if [[ "$REPLY" == "y" || "$REPLY" == "Y" ]]; then
    while true; do
    echo 
    read -p "Please enter the OCI compartment ID: " compartment
    compartment_info=$(oci iam compartment get --compartment-id "$compartment" 2>&1)

    if [ $? -eq 0 ]; then
        compartment_name=$(echo "$compartment_info" | jq -r '.data.name')
        compartment_id=$(echo "$compartment_info" | jq -r '.data.id')
        echo "Using the Compartment  $compartment_name / $compartment_id"

        # build path for policy
        # NOTE: quote the command substitution - compartment names may contain
        # spaces, and unquoted expansion would split one path into several
        # bogus array entries (and therefore several malformed policy statements).
        if [[ "$compartment_id" != "$TENANT_ID" ]]; then
            compartment_names+=("$(build_compartment_path "$compartment_id")")

        else
            USING_ROOT_COMPARTMENT=true
        fi
    else
         # Print the error message from OCI CLI
        echo "Failed to retrieve compartment information. Error:"
        echo "$compartment_info"
        exit 1
    fi

        # Ask the user if they want to add a compartment
        read -p "Do you want to add more existing OCI compartments? (Y/N): " answer

        if [[ "$answer" == "n" || "$answer" == "N" || "$answer" == "no" ]]; then
            # User finished adding compartments, break out of the loop
            break
        fi
    done

else
    echo    
    echo "Getting list of compartments"
    ALL_COMPARTMENTS=$(oci iam compartment list --compartment-id-in-subtree true --all --include-root  --query "data[].{"name":name,"id":id}")
    # echo $ALL_COMPARTMENTS
    declare -A display_name_map
    declare -A compartment_id_map

    index=0
    while IFS= read -r line; do
        display_name=$(echo "$line" | jq -r '.name | @sh')
        compartment_id=$(echo "$line" | jq -r '.id')

        display_name_map[$index]=$display_name
        compartment_id_map[$index]=$compartment_id

        ((index++))
    done < <(echo "$ALL_COMPARTMENTS" | jq -c '.[]')

    while true; do
        length=${#display_name_map[@]}
        for ((i = 0; i < length; i++)); do
            display_name="${display_name_map[$i]}"
            id="${compartment_id_map[$i]}"
            
            echo "$i $display_name/ $id"
        done
        length=$(($length-1))
        read -p "Enter number from 0 - $length: " compartment_selection
        if [[ -z $compartment_selection ]]; then
            read -p "Enter number from 0 - $length: " compartment_selection
        fi
        echo "selection $compartment_selection" 
        echo "Using the Compartment  ${display_name_map[$compartment_selection]} / ${compartment_id_map[$compartment_selection]}"
        COMPARTMENT_NAME=${display_name_map[$compartment_selection]}
        COMPARTMENT_ID=${compartment_id_map[$compartment_selection]}

        if [[ "$COMPARTMENT_ID" != "$TENANT_ID" ]]; then
            compartment_names+=("$(build_compartment_path "$COMPARTMENT_ID")")

        else
            USING_ROOT_COMPARTMENT=true
        fi

        # Prefix the selected compartment's display name with [ALREADY SELECTED]
        display_name_map[$compartment_selection]="****[ALREADY SELECTED]**** ${display_name_map[$compartment_selection]}"

        # Ask the user if they want to add a compartment
        read -p "Do you want to add more existing OCI compartments? (Y/N): " answer

        if [[ "$answer" == "n" || "$answer" == "N" || "$answer" == "no" ]]; then
            # User finished adding compartments, break out of the loop
            break
        fi
    done
fi
     

# read -p "Do you want to create a new compartment ?[y/n] " -n 1

# new_comp=$REPLY
# if [[ "$REPLY" == "y" || "$REPLY" == "Y" ]]; then
#     echo
#     echo "Getting list ofcompartments"
#     ALL_COMPARTMENTS=$(oci iam compartment list --compartment-id-in-subtree true --all --include-root --query "data[].{"name":name,"id":id}" )
#     # echo $ALL_COMPARTMENTS
#     declare -A display_name_map
#     declare -A compartment_id_map

#     index=0
#     while IFS= read -r line; do
#         display_name=$(echo "$line" | jq -r '.name | @sh')
#         compartment_id=$(echo "$line" | jq -r '.id')

#         display_name_map[$index]=$display_name
#         compartment_id_map[$index]=$compartment_id

#         ((index++))
#     done < <(echo "$ALL_COMPARTMENTS" | jq -c '.[]')
    
#     length=${#display_name_map[@]}
#     for ((i = 0; i < length; i++)); do
#         display_name="${display_name_map[$i]}"
#         App_id="${compartment_id_map[$i]}"
        
#         echo "$i $display_name/ $app_id"
#     done
#     length=$(($length-1))
#     read -p "Enter number from 0 - $length for the root compartment: " compartment_selection
#     if [[ -z $compartment_selection ]]; then
#         read -p "Enter number from 0 - $length for the root compartment: " compartment_selection
#     fi
#     echo 
#     echo "selection $compartment_selection" 
#     echo "Using the Compartment  ${display_name_map[$compartment_selection]} / ${compartment_id_map[$compartment_selection]} as root"
#     echo "creating new compartment " $PREFIX-compartment
#     result=$(oci iam compartment create --name $PREFIX-compartment --description "Created by Cisco Multicloud defence"  --compartment-id ${compartment_id_map[$compartment_selection]} --query "data.{"name":name,"id":id}")
#     echo $result
#     COMPARTMENT_NAME=$(echo $result | jq -r '.name | @sh')
#     COMPARTMENT_ID=$(echo $result | jq -r '.id')

#     echo " waiting for compartment to be Active "
#     sleep 5
#     wait_until_compartment_active $COMPARTMENT_ID
#     #compartment_names+=("$(echo $result | jq -r '.name | @sh' | tr -d "\'")")
#     compartment_names+=($(build_compartment_path $COMPARTMENT_ID))
#     echo created Compartment $COMPARTMENT_ID $COMPARTMENT_NAME
# fi

echo
# Idempotency: reuse an existing group/policy/user of the same name instead of
# failing the whole run. Only resources this run actually creates are recorded
# in the uninstaller, so a re-run never deletes something it did not create.
CREATED_GROUP=false
CREATED_POLICY=false
CREATED_USER=false
CREATED_MEMBERSHIP=false

GROUP_NAME="$PREFIX-controller-group"
GROUP_ID=$(oci iam group list --compartment-id "$TENANT_ID" --name "$GROUP_NAME" --all 2>/dev/null | jq -r '.data[0].id // empty')

if [[ -n "$GROUP_ID" ]]; then
    echo "Group $GROUP_NAME already exists, reusing it: $GROUP_ID"
else
    echo "Creating group $GROUP_NAME"
    if ! result=$(oci iam group create --description "created by Cisco MultiCloud Defence" --name "$GROUP_NAME" 2>&1); then
        echo "Failed to create group $GROUP_NAME:"
        echo "$result"
        exit 1
    fi
    GROUP_ID=$(echo "$result" | jq -r '.data.id')
    CREATED_GROUP=true
    echo "created Group $GROUP_ID $GROUP_NAME"
fi

echo 
echo "Creating Policy" $PREFIX-controller-policy

policy_file="/tmp/policy.txt"

# Start the JSON policy file with an opening bracket
echo "[" > "$policy_file"

if [[ "$USING_ROOT_COMPARTMENT" == "true" ]]; then
    root_policy_statement="\"Allow group $GROUP_NAME to inspect instance-images in tenancy\",
\"Allow group $GROUP_NAME to read app-catalog-listing in tenancy\",
\"Allow group $GROUP_NAME to use volume-family in tenancy\",
\"Allow group $GROUP_NAME to manage virtual-network-family in tenancy\",
\"Allow group $GROUP_NAME to manage volume-attachments in tenancy\",
\"Allow group $GROUP_NAME to manage instances in tenancy\",
\"Allow group $GROUP_NAME to manage load-balancers in tenancy\",
\"Allow group $GROUP_NAME to manage app-catalog-listing in tenancy\","
    echo "$root_policy_statement" >> "$policy_file"
fi


# Loop over each compartment name and create policy statements
for COMPARTMENT_NAME in "${compartment_names[@]}"; do
    # Generate the policy statement and append it to the policy file
    policy_statement="\"Allow group $GROUP_NAME to inspect instance-images in compartment $COMPARTMENT_NAME\",
\"Allow group $GROUP_NAME to read app-catalog-listing in compartment $COMPARTMENT_NAME\",
\"Allow group $GROUP_NAME to use volume-family in compartment $COMPARTMENT_NAME\",
\"Allow group $GROUP_NAME to manage virtual-network-family in compartment $COMPARTMENT_NAME\",
\"Allow group $GROUP_NAME to manage volume-attachments in compartment $COMPARTMENT_NAME\",
\"Allow group $GROUP_NAME to manage instances in compartment $COMPARTMENT_NAME\",
\"Allow group $GROUP_NAME to manage load-balancers in compartment $COMPARTMENT_NAME\",
\"Allow group $GROUP_NAME to manage app-catalog-listing in compartment $COMPARTMENT_NAME\","
    echo "$policy_statement" >> "$policy_file"
done

# add generic statemets into the policy
extra_policy_statement="\"Allow group $GROUP_NAME to read marketplace-listings in tenancy\",
\"Allow group $GROUP_NAME to read marketplace-community-listings in tenancy\",
\"Allow group $GROUP_NAME to inspect compartments in tenancy\",
\"Allow group $GROUP_NAME to read virtual-network-family in tenancy\",
\"Allow group $GROUP_NAME to read instance-family in tenancy\",
\"Allow group $GROUP_NAME to read load-balancers in tenancy\",
\"Allow group $GROUP_NAME to manage cloudevents-rules in tenancy\",
\"Allow group $GROUP_NAME to manage ons-family in tenancy\""

echo "$extra_policy_statement" >> "$policy_file"

# End the JSON policy file with a closing bracket
echo "]" >> "$policy_file"


echo "Created file /tmp/policy.txt"

POLICY_NAME="$PREFIX-controller-policy"
POLICY_ID=$(oci iam policy list --compartment-id "$TENANT_ID" --name "$POLICY_NAME" --all 2>/dev/null | jq -r '.data[0].id // empty')

if [[ -n "$POLICY_ID" ]]; then
    echo "Policy $POLICY_NAME already exists ($POLICY_ID), updating its statements"
    if ! result=$(oci iam policy update --policy-id "$POLICY_ID" --statements file:///tmp/policy.txt --force 2>&1); then
        echo "Failed to update policy $POLICY_NAME:"
        echo "$result"
        exit 1
    fi
else
    echo "Creating policy $POLICY_NAME"
    if ! result=$(oci iam policy create --compartment-id "$TENANT_ID" --description "Multicloud Defence Controller policy" --name "$POLICY_NAME" --statements file:///tmp/policy.txt 2>&1); then
        echo "Failed to create policy $POLICY_NAME:"
        echo "$result"
        exit 1
    fi
    POLICY_ID=$(echo "$result" | jq -r '.data.id')
    CREATED_POLICY=true
fi
echo "Policy ready: $POLICY_ID $POLICY_NAME"



USER_NAME="$PREFIX-controller-user"
USER_ID=$(oci iam user list --compartment-id "$TENANT_ID" --name "$USER_NAME" --all 2>/dev/null | jq -r '.data[0].id // empty')

if [[ -n "$USER_ID" ]]; then
    echo "User $USER_NAME already exists, reusing it: $USER_ID"
else
    echo "Creating user $USER_NAME"

    # Ask if the user wants to enter an email ID
    read -rp "Do you want to enter an email ID for the user? (y/n): " enter_email

    if [[ "$enter_email" == "y" || "$enter_email" == "Y" ]]; then
        # Prompt for email ID
        read -rp "Enter the email ID for the user: " email_id
        result=$(oci iam user create --name "$USER_NAME" --description "MultiCloud Defence Controller user" --email "$email_id" 2>&1)
    else
        result=$(oci iam user create --name "$USER_NAME" --description "MultiCloud Defence Controller user" 2>&1)
    fi

    if [[ $? -ne 0 ]]; then
        echo "Failed to create user $USER_NAME:"
        echo "$result"
        exit 1
    fi

    USER_ID=$(echo "$result" | jq -r '.data.id')
    CREATED_USER=true
    echo "created User $USER_ID $USER_NAME"
fi

# Add to group only if not already a member
existing_membership=$(oci iam group list-users --group-id "$GROUP_ID" --all 2>/dev/null | jq -r --arg uid "$USER_ID" '.data[] | select(.id == $uid) | .id // empty')

if [[ -n "$existing_membership" ]]; then
    echo "User $USER_NAME is already a member of group $GROUP_NAME"
else
    echo "Adding user $USER_NAME to group $GROUP_NAME"
    if ! result=$(oci iam group add-user --user-id "$USER_ID" --group-id "$GROUP_ID" 2>&1); then
        echo "Failed to add user $USER_NAME to group $GROUP_NAME:"
        echo "$result"
        exit 1
    fi
    MEMBERSHIP_ID=$(echo "$result" | jq -r '.data.id')
    CREATED_MEMBERSHIP=true
fi

# Prompt for user input
read -rp "Enter the directory to store API keys (e.g., /home/user/.oci/) or press Enter for the default [~/.oci/]: " api_key_dir
read -rp "Enter a name for the API key (e.g., my_api_key): " key_name

# Set default directory if none provided
api_key_dir=${api_key_dir:-$HOME/.oci}

# Ensure the API key directory exists
mkdir -p "${api_key_dir}"

# File paths for the private and public keys
private_key_path="${api_key_dir}/${key_name}_private.pem"
public_key_path="${api_key_dir}/${key_name}_public.pem"

# Generate the private key
openssl genpkey -algorithm RSA -out "${private_key_path}" -pkeyopt rsa_keygen_bits:2048
# Set the private key's permissions to ensure it is kept secure
chmod 600 "${private_key_path}"

# Generate the public key from the private key
openssl rsa -pubout -in "${private_key_path}" -out "${public_key_path}"

# Read the private key into a variable
PRIVATE_KEY=$(<"${private_key_path}")

# OCI allows at most 3 API keys per user. On a re-run against an existing user
# this upload can fail once that limit is reached - report it clearly rather
# than leaving the operator with an unusable key pair on disk.
existing_key_count=$(oci iam user api-key list --user-id "$USER_ID" --all 2>/dev/null | jq -r '.data | length // 0')
if [[ -n "$existing_key_count" && "$existing_key_count" -ge 3 ]]; then
    echo "WARNING: user $USER_NAME already has $existing_key_count API keys (OCI allows 3)."
    echo "         The upload below will fail unless you delete an unused key first:"
    echo "         oci iam user api-key list --user-id $USER_ID"
fi

# Upload the public key to OCI
upload_output=$(oci iam user api-key upload --user-id "$USER_ID" --key-file "$public_key_path" 2>&1)
upload_rc=$?

# Check if the upload was successful and capture the key's fingerprint
if [[ $upload_rc -eq 0 ]]; then
    api_key_fingerprint=$(echo "$upload_output" | jq -r '.data.fingerprint')

    echo "API key uploaded successfully."
    echo "API key fingerprint $api_key_fingerprint"
    echo "Private key path: $private_key_path"
    echo "Public key path: $public_key_path"
else
    echo "Failed to upload the API key to OCI."
    echo "$upload_output"
fi


cleanup_file="delete-oci-cisco-mcd-setup.sh"
echo "Created uninstaller script in the current directory '$cleanup_file'"

# The uninstaller only removes what THIS run created. Anything that already
# existed and was reused is left alone, so re-running the onboarding script
# and then the uninstaller cannot destroy a pre-existing setup.
{
    echo "#! /bin/bash"

    if [[ -n "$api_key_fingerprint" && "$api_key_fingerprint" != "null" ]]; then
        echo "echo Delete api key with fingerprint $api_key_fingerprint"
        echo "oci iam user api-key delete --user-id $USER_ID --fingerprint $api_key_fingerprint --force"
    fi

    if [[ "$CREATED_MEMBERSHIP" == "true" ]]; then
        echo "echo Remove user $USER_NAME from group $GROUP_NAME"
        echo "oci iam group remove-user --user-id $USER_ID --group-id $GROUP_ID --force"
    fi

    if [[ "$CREATED_POLICY" == "true" ]]; then
        echo "echo Delete Iam Policy $POLICY_NAME"
        echo "oci iam policy delete --policy-id $POLICY_ID --force"
    else
        echo "echo Policy $POLICY_NAME pre-existed this run - not deleting"
    fi

    if [[ "$CREATED_GROUP" == "true" ]]; then
        echo "echo Delete Group $GROUP_NAME"
        echo "oci iam group delete --group-id $GROUP_ID --force"
    else
        echo "echo Group $GROUP_NAME pre-existed this run - not deleting"
    fi

    if [[ "$CREATED_USER" == "true" ]]; then
        echo "echo Delete User $USER_NAME"
        echo "oci iam user delete --user-id $USER_ID --force"
    else
        echo "echo User $USER_NAME pre-existed this run - not deleting"
    fi

    echo "rm \$0"
} > "$cleanup_file"

chmod +x $cleanup_file

echo
echo "----------------------------------------------------------------------------------------------------"
echo "Information shown below is needed to onboard Tenant/Compartment to the Cisco Multicloud Defense Controller"
echo "----------------------------------------------------------------------------------------------------"
echo "Tenancy OCID : $TENANT_ID"
echo
echo "User OCID    : $USER_ID"    
echo
echo "Private Key  : "   
echo " $PRIVATE_KEY "
echo "----------------------------------------------------------------------------------------------------"