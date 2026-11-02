#!/bin/bash

buckets=$(aws s3api list-buckets --query 'Buckets[?starts_with(Name, `pss-support`) == `true`].Name' --output text)

for bucketname in $buckets
do
	        echo "Processing bucket $bucketname"
		        ./delete_bucket.sh $bucketname
		done
