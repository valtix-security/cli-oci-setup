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






read -p "Do you want to use existing Compartment (y) or create new(n) ? [y/n] " -n 1

existing_sub=$REPLY
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

    length=${#display_name_map[@]}
    for ((i = 0; i < length; i++)); do
        display_name="${display_name_map[$i]}"
        App_id="${compartment_id_map[$i]}"
        
        echo "$i $display_name/ $app_id"
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
     

else
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
    echo oci iam compartment create --name $PREFIX-compartment --description \"Created by Cisco Multicloud defence \" --compartment-id ${compartment_id_map[$compartment_selection]}
    result=$(oci iam compartment create --name $PREFIX-compartment --description "Created by Cisco Multicloud defence"  --compartment-id ${compartment_id_map[$compartment_selection]} --query "data.{"name":name,"id":id}")
    echo $result
    COMPARTMENT_NAME=$(echo $result | jq -r '.name | @sh')
    COMPARTMENT_ID=$(echo $result | jq -r '.id')
    echo created Compartment $COMPARTMENT_ID $COMPARTMENT_NAME
fi

echo 
echo  "Creating group" $PREFIX-controller-group
result=$(oci iam group create --description "created by Cisco MultiCloud Defence" --name $PREFIX-controller-group --query "data.{"name":name,"id":id}")
GROUP_NAME=$(echo $result | jq -r '.name | @sh')
GROUP_ID=$(echo $result | jq -r '.id')
echo created Group  $GROUP_ID $GROUP_NAME



echo 
echo "Creating Policy" $PREFIX-controller-policy

cat > /tmp/policy.json <<- EOF
[
    "Allow group $GROUP_NAME to inspect instance-images in compartment $COMPARTMENT_NAME"
    "Allow group $GROUP_NAME to read app-catalog-listing in compartment $COMPARTMENT_NAME"
    "Allow group $GROUP_NAME to use volume-family in compartment $COMPARTMENT_NAME"
    "Allow group $GROUP_NAME to use virtual-network-family in compartment $COMPARTMENT_NAME"
    "Allow group $GROUP_NAME to manage volume-attachments in compartment $COMPARTMENT_NAME"
    "Allow group $GROUP_NAME to manage instances in compartment $COMPARTMENT_NAME"
    "Allow group $GROUP_NAME to {INSTANCE_IMAGE_READ} in compartment $COMPARTMENT_NAME"
    "Allow group $GROUP_NAME to manage load-balancers in compartment $COMPARTMENT_NAME"
    "Allow group $GROUP_NAME to read marketplace-listings in tenancy"
    "Allow group $GROUP_NAME to read marketplace-community-listings in tenancy"
    "Allow group $GROUP_NAME to inspect compartments in tenancy"
    "Allow group $GROUP_NAME to manage app-catalog-listing in compartment $COMPARTMENT_NAME"
]
EOF
echo "Created file /tmp/policy.json" 
echo "Creating policy"
echo oci iam policy create --compartment-id --description "Multicloud Defence Controller policy" --name $prefix-policy --statements file://tmp/policy.json --query "data.{"name":name,"id":id}"
result=$(oci iam policy create --compartment-id --description "Multicloud Defence Controller policy" --name $prefix-policy --statements file://tmp/policy.json --query "data.{"name":name,"id":id}")
echo $result
POLICY_NAME=$(echo $result | jq -r '.name | @sh')
POLICY_ID=$(echo $result | jq -r '.id')
echo created Policy  $POLICY_ID $POLICY_NAME



echo "Creating user" $PREFIX-controller-user

result=$(oci iam user create --name $$PREFIX-controller-user --description "MultiCloud Defence Controller user" --query "data.{"name":name,"id":id}")
USER_NAME=$(echo $result | jq -r '.name | @sh')
USER_ID=$(echo $result | jq -r '.id')
echo created User  $USER_ID $USER_NAME




