# Use AWS Lambda Python base image
FROM public.ecr.aws/lambda/python:3.12

# Copy the Lambda function code
COPY lambda_function.py ${LAMBDA_TASK_ROOT}

# Set the CMD to the Lambda handler
CMD ["lambda_function.lambda_handler"]