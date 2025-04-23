def lambda_handler(event, context):
    # Extract numbers from event, default to 0 if not provided
    num1 = event.get('num1', 0)
    num2 = event.get('num2', 0)
    
    # Perform addition
    result = num1 + num2
    
    # Return response
    return {
        'statusCode': 200,
        'body': f"Sum of {num1} and {num2} is {result}"
    }