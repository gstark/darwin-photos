#!/bin/bash
# Creates the IAM user that Shoebox uses for scheduled backups, and saves its
# access key in the login Keychain, where the app reads it.
#
#   scripts/create-backup-iam-user.sh [ADMIN_PROFILE]
#
# ADMIN_PROFILE is an AWS profile that can manage IAM users. The default is
# the "s3.profile" value in ~/.shoebox/config.json.
#
# The user can only:
#   - list the bucket (s3:ListBucket), which the backup needs to find the
#     objects that exist, and
#   - add objects under the backup prefix (s3:PutObject, s3:AbortMultipartUpload).
# It cannot read or delete objects. s3:PutObject can replace an object with
# the same key, so turn on bucket versioning to protect existing backups.
#
# Running the script again keeps the user, updates the policy, and replaces
# the access key.
set -euo pipefail

CONFIG="$HOME/.shoebox/config.json"
JQ=$(command -v jq)
AWS=$(command -v aws)
USER_NAME=darwin-photos-backup
POLICY_NAME=darwin-photos-backup

DESTINATION=$("$JQ" -r '.destination // empty' "$CONFIG")
PROFILE=${1:-$("$JQ" -r '.s3.profile // empty' "$CONFIG")}
if [[ "$DESTINATION" != s3://* ]]; then
  echo "The destination in $CONFIG is not an s3:// URI: $DESTINATION" >&2
  exit 1
fi
BUCKET=$(echo "${DESTINATION#s3://}" | /usr/bin/cut -d/ -f1)
PREFIX=$(echo "${DESTINATION#s3://$BUCKET}" | /usr/bin/sed -E 's#^/+##; s#/+$##')
OBJECTS="arn:aws:s3:::$BUCKET/${PREFIX:+$PREFIX/}*"
aws() { "$AWS" ${PROFILE:+--profile "$PROFILE"} "$@"; }

echo "Bucket:  $BUCKET"
echo "Objects: $OBJECTS"
echo "Profile: ${PROFILE:-default}"
echo ""

if aws iam get-user --user-name "$USER_NAME" > /dev/null 2>&1; then
  echo "The user $USER_NAME exists."
else
  aws iam create-user --user-name "$USER_NAME" \
    --tags Key=purpose,Value="darwin-photos scheduled backups" > /dev/null
  echo "Created the user $USER_NAME."
fi

POLICY=$("$JQ" -n --arg bucket "arn:aws:s3:::$BUCKET" --arg objects "$OBJECTS" '{
  Version: "2012-10-17",
  Statement: [
    {Sid: "FindExistingBackups", Effect: "Allow", Action: "s3:ListBucket", Resource: $bucket},
    {Sid: "AddBackups", Effect: "Allow", Action: ["s3:PutObject", "s3:AbortMultipartUpload"], Resource: $objects}
  ]
}')
aws iam put-user-policy --user-name "$USER_NAME" --policy-name "$POLICY_NAME" --policy-document "$POLICY"
echo "Set the policy $POLICY_NAME."

# An IAM user can have two keys. Remove the old keys, so this run's key is
# the only one.
for OLD in $(aws iam list-access-keys --user-name "$USER_NAME" | "$JQ" -r '.AccessKeyMetadata[].AccessKeyId'); do
  aws iam delete-access-key --user-name "$USER_NAME" --access-key-id "$OLD"
  echo "Deleted the old access key $OLD."
done
KEY=$(aws iam create-access-key --user-name "$USER_NAME")
KEY_ID=$(echo "$KEY" | "$JQ" -r '.AccessKey.AccessKeyId')
ITEM=$(echo "$KEY" | "$JQ" -c '{id: .AccessKey.AccessKeyId, secret: .AccessKey.SecretAccessKey}')
/usr/bin/security add-generic-password -U -s com.gstark.shoebox -a aws-access-key \
  -l "shoebox AWS access key" -w "$ITEM"
echo "Created the access key $KEY_ID and saved it in the login Keychain."

echo ""
# The response is empty for a bucket that never had versioning.
VERSIONING=$(aws s3api get-bucket-versioning --bucket "$BUCKET" | "$JQ" -r '.Status // empty')
VERSIONING=${VERSIONING:-Off}
echo "Bucket versioning: $VERSIONING"
if [ "$VERSIONING" != Enabled ]; then
  echo "Turn on versioning, so that a replaced object keeps its old version:"
  echo "  aws ${PROFILE:+--profile $PROFILE }s3api put-bucket-versioning --bucket $BUCKET --versioning-configuration Status=Enabled"
fi
echo ""
echo "In Shoebox, open Settings > Destination, and set Sign in with to Access key."
echo "IAM changes can take a few seconds to apply."
