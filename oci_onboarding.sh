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
            PREFIX=${OPTARG}
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

read -p "Do you want to use any existing Compartments (y)  ? [y/n] " -n 1

existing_comp=$REPLY
if [[ "$REPLY" == "y" || "$REPLY" == "Y" ]]; then
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
            compartment_names+=($(build_compartment_path "$COMPARTMENT_ID"))

        else
            USING_ROOT_COMPARTMENT=true
        fi

        # remove the selected compartmet from the map 
        unset display_name_map[$compartment_selection]
        unset compartment_id_map[$compartment_selection]

        # Ask the user if they want to add a compartment
        read -p "Do you want to add more existing OCI compartments? (Y/N): " answer

        if [[ "$answer" == "n" || "$answer" == "N" || "$answer" == "no" ]]; then
            # User finished adding compartments, break out of the loop
            break
        fi
    done
fi
     

read -p "Do you want to create a new compartment ?[y/n] " -n 1

new_comp=$REPLY
if [[ "$REPLY" == "y" || "$REPLY" == "Y" ]]; then
    echo
    echo "Getting list ofcompartments"
    ALL_COMPARTMENTS=$(oci iam compartment list --compartment-id-in-subtree true --all --include-root --query "data[].{"name":name,"id":id}" )
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
    
    length=${#display_name_map[@]}
    for ((i = 0; i < length; i++)); do
        display_name="${display_name_map[$i]}"
        App_id="${compartment_id_map[$i]}"
        
        echo "$i $display_name/ $app_id"
    done
    length=$(($length-1))
    read -p "Enter number from 0 - $length for the root compartment: " compartment_selection
    if [[ -z $compartment_selection ]]; then
        read -p "Enter number from 0 - $length for the root compartment: " compartment_selection
    fi
    echo 
    echo "selection $compartment_selection" 
    echo "Using the Compartment  ${display_name_map[$compartment_selection]} / ${compartment_id_map[$compartment_selection]} as root"
    echo "creating new compartment " $PREFIX-compartment
    result=$(oci iam compartment create --name $PREFIX-compartment --description "Created by Cisco Multicloud defence"  --compartment-id ${compartment_id_map[$compartment_selection]} --query "data.{"name":name,"id":id}")
    echo $result
    COMPARTMENT_NAME=$(echo $result | jq -r '.name | @sh')
    COMPARTMENT_ID=$(echo $result | jq -r '.id')

    echo " waiting for compartment to be Active "
    sleep 5
    wait_until_compartment_active $COMPARTMENT_ID
    #compartment_names+=("$(echo $result | jq -r '.name | @sh' | tr -d "\'")")
    compartment_names+=($(build_compartment_path $COMPARTMENT_ID))
    echo created Compartment $COMPARTMENT_ID $COMPARTMENT_NAME
fi

echo 
echo  "Creating group" $PREFIX-controller-group
result=$(oci iam group create --description "created by Cisco MultiCloud Defence" --name $PREFIX-controller-group --query "data.{"name":name,"id":id}")
GROUP_NAME=$(echo $result | jq -r '.name | @sh' | tr -d "\'")
GROUP_ID=$(echo $result | jq -r '.id')
echo created Group  $GROUP_ID $GROUP_NAME

echo 
echo "Creating Policy" $PREFIX-controller-policy

policy_file="/tmp/policy.txt"

# Start the JSON policy file with an opening bracket
echo "[" > "$policy_file"

if [[ "$USING_ROOT_COMPARTMENT" == "true" ]]; then
    root_policy_statement="\"Allow group $GROUP_NAME to inspect instance-images in tenancy\",
\"Allow group $GROUP_NAME to read app-catalog-listing in tenancy\",
\"Allow group $GROUP_NAME to use volume-family in tenancy\",
\"Allow group $GROUP_NAME to use virtual-network-family in tenancy\",
\"Allow group $GROUP_NAME to manage volume-attachments in tenancy\",
\"Allow group $GROUP_NAME to manage instances in tenancy\",
\"Allow group $GROUP_NAME to {INSTANCE_IMAGE_READ}in tenancy\",
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
\"Allow group $GROUP_NAME to use virtual-network-family in compartment $COMPARTMENT_NAME\",
\"Allow group $GROUP_NAME to manage volume-attachments in compartment $COMPARTMENT_NAME\",
\"Allow group $GROUP_NAME to manage instances in compartment $COMPARTMENT_NAME\",
\"Allow group $GROUP_NAME to {INSTANCE_IMAGE_READ} in compartment $COMPARTMENT_NAME\",
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
\"Allow group $GROUP_NAME to read load-balancers in tenancy\""

echo "$extra_policy_statement" >> "$policy_file"

# End the JSON policy file with a closing bracket
echo "]" >> "$policy_file"


echo "Created file /tmp/policy.txt" 
echo "Creating policy"
result=$(oci iam policy create --compartment-id $TENANT_ID --description "Multicloud Defence Controller policy" --name $PREFIX-controller-policy --statements file:///tmp/policy.txt --query "data.{"name":name,"id":id}")
echo $result
POLICY_NAME=$(echo $result | jq -r '.name | @sh')
POLICY_ID=$(echo $result | jq -r '.id')
echo created Policy  $POLICY_ID $POLICY_NAME



echo "Creating user" $PREFIX-controller-user

result=$(oci iam user create --name $PREFIX-controller-user --description "MultiCloud Defence Controller user" --query "data.{"name":name,"id":id}")
USER_NAME=$(echo $result | jq -r '.name | @sh')
USER_ID=$(echo $result | jq -r '.id')
echo created User  $USER_ID $USER_NAME

echo "Adding user" $USER_NAME "to group" $GROUP_NAME

result=$(oci iam group add-user --user-id $USER_ID --group-id $GROUP_ID --query "data.{"id":id}")
MEMBERSHIP_ID=$(echo $result | jq -r '.id')

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

# Upload the public key to OCI
upload_output=$(oci iam user api-key upload --user-id $USER_ID --key-file $public_key_path 2>&1)

# Check if the upload was successful and capture the key's OCID
if [[ $? -eq 0 ]]; then
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
echo "Created uninstaller script in the current directory '$cleanup_file': Note run script with tennants base region parameter to delete compartment created with this script "
echo " example : ./'$cleanup_file' us-sanjose-1 "

if [[ "$new_comp" == "n"  || "$new_comp" == "N" ]]; then

cat > $cleanup_file <<- EOF
REGION="$1"
echo Delete api key 
oci iam user api-key delete --user-id $USER_ID --fingerprint $api_key_fingerprint
echo Delete user $USER_NAME from group $GROUP_NAME
oci iam group remove-user --user-id $USER_ID --group-id $GROUP_ID
echo Delete Iam Policy $POLICY_NAME
oci iam policy delete --policy-id $POLICY_ID
echo Delete Group $GROUP_NAME
oci iam group delete --group-id $GROUP_ID
echo Delete User $USER_NAME
oci iam user delete --user-id $USER_ID
rm $cleanup_file

EOF

else

cat > $cleanup_file <<- EOF
REGION="$1"
echo Delete api key 
oci iam user api-key delete --user-id $USER_ID --fingerprint $api_key_fingerprint
echo Delete user $USER_NAME from group $GROUP_NAME
oci iam group remove-user --user-id $USER_ID --group-id $GROUP_ID
echo Delete Iam Policy $POLICY_NAME
oci iam policy delete --policy-id $POLICY_ID
echo Delete Group $GROUP_NAME
oci iam group delete --group-id $GROUP_ID
echo Delete User $USER_NAME
oci iam user delete --user-id $USER_ID
echo Deleteing compartment $COMPARTMENT_NAME 
oci raw-request --target-uri https://identity.$REGION.oraclecloud.com/20160918/compartments/$COMPARTMENT_ID --http-method DELETE
EOF

fi
chmod +x $cleanup_file

echo
echo "----------------------------------------------------------------------------------------------------"
echo "Information shown below is needed to onboard subscription to the Cisco Multicloud Defense Controller"
echo "----------------------------------------------------------------------------------------------------"
echo "Tenant/Directory  : $TENANT_ID"
echo
echo " User_Id          : $USER_ID"    
echo
echo " Private key      : $PRIVATE_KEY"   
echo "----------------------------------------------------------------------------------------------------"