package controller

import (
	"context"
	"os"
	"testing"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/ecr"
)

func TestLocalStackECRAuthorization(t *testing.T) {
	if os.Getenv("LOCALSTACK_INTEGRATION") != "1" {
		t.Skip("set LOCALSTACK_INTEGRATION=1 to run against LocalStack")
	}

	endpoint := os.Getenv("LOCALSTACK_ENDPOINT")
	if endpoint == "" {
		endpoint = os.Getenv("AWS_ENDPOINT_URL")
	}
	if endpoint == "" {
		endpoint = "http://localhost:4566"
	}
	region := os.Getenv("AWS_REGION")
	if region == "" {
		region = "us-east-1"
	}
	awsConfig, err := config.LoadDefaultConfig(context.Background(),
		config.WithRegion(region),
		config.WithBaseEndpoint(endpoint),
		config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider("test", "test", "")),
	)
	if err != nil {
		t.Fatal(err)
	}

	output, err := ecr.NewFromConfig(awsConfig).GetAuthorizationToken(context.Background(), &ecr.GetAuthorizationTokenInput{
		RegistryIds: []string{"000000000000"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(output.AuthorizationData) == 0 || output.AuthorizationData[0].AuthorizationToken == nil {
		t.Fatalf("LocalStack returned no ECR authorization token: %#v", output)
	}
}
