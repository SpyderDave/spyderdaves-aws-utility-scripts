import boto3

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('THCPAccountDetails')

def remove_attribute():
    # Scan the table to find all items
    response = table.scan()
    items = response.get('Items', [])
    
    # Handle pagination if your table is large
    while 'LastEvaluatedKey' in response:
        response = table.scan(ExclusiveStartKey=response['LastEvaluatedKey'])
        items.extend(response.get('Items', []))
        
    print(f"Found {len(items)} items to process.")

    # Loop through and remove the attribute from each item
    for item in items:
        table.update_item(
            Key={
                'AccountId': item['AccountId'] # Replace with your actual Partition Key (and Sort Key if applicable)
            },
            UpdateExpression='REMOVE Lacework'
        )
    print("Attribute removal complete.")

remove_attribute()
