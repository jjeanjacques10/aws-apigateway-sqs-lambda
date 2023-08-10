package main

import (
	"context"
	"log"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/sqs"
)

func main() {
	lambda.Start(handler)
}

func handler(ctx context.Context, event events.SQSEvent) error {
	log.Println("Hello world")

	for _, record := range event.Records {
		message := record.Body
		log.Printf("Received SQS message: %s\n", message)

		if err := deleteMessage(record.ReceiptHandle, record.EventSourceARN); err != nil {
			log.Printf("Error deleting message: %v\n", err)
		}
	}

	return nil
}

func deleteMessage(receiptHandle, queueURL string) error {
	sess := session.Must(session.NewSession())
	svc := sqs.New(sess)

	params := &sqs.DeleteMessageInput{
		QueueUrl:      &queueURL,
		ReceiptHandle: &receiptHandle,
	}

	_, err := svc.DeleteMessage(params)
	return err
}
