package controller

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/ecr"
	"github.com/aws/aws-sdk-go-v2/service/ecr/types"
)

type countingTokenClient struct {
	mu    sync.Mutex
	calls int
}

func (c *countingTokenClient) GetAuthorizationToken(context.Context, *ecr.GetAuthorizationTokenInput, ...func(*ecr.Options)) (*ecr.GetAuthorizationTokenOutput, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.calls++
	token := base64.StdEncoding.EncodeToString([]byte("AWS:secret"))
	return &ecr.GetAuthorizationTokenOutput{AuthorizationData: []types.AuthorizationData{{AuthorizationToken: &token}}}, nil
}

func (c *countingTokenClient) callCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.calls
}

func TestRegistryFromRepository(t *testing.T) {
	registry, err := registryFromRepository("123456789012.dkr.ecr.us-east-1.amazonaws.com/rosa/release")
	if err != nil || registry != "123456789012.dkr.ecr.us-east-1.amazonaws.com" {
		t.Fatalf("registry = %q, err = %v", registry, err)
	}
	if _, err := registryFromRepository("not-a-repository"); err == nil {
		t.Fatal("expected repository without a path to fail")
	}
}

func TestDockerConfig(t *testing.T) {
	token := base64.StdEncoding.EncodeToString([]byte("AWS:secret"))
	data := dockerConfig("123456789012.dkr.ecr.us-east-1.amazonaws.com", types.AuthorizationData{AuthorizationToken: &token})
	var config struct {
		Auths map[string]struct {
			Auth string `json:"auth"`
		} `json:"auths"`
	}
	if err := json.Unmarshal(data, &config); err != nil {
		t.Fatal(err)
	}
	if config.Auths["123456789012.dkr.ecr.us-east-1.amazonaws.com"].Auth != token {
		t.Fatalf("unexpected auth config: %s", data)
	}
}

func TestAccountFromRegistry(t *testing.T) {
	if got := accountFromRegistry("123456789012.dkr.ecr.us-east-1.amazonaws.com"); got != "123456789012" {
		t.Fatalf("account = %q", got)
	}
	if got := accountFromRegistry("public.ecr.aws"); got != "" {
		t.Fatalf("account = %q", got)
	}
}

func TestAuthorizationUsesSharedTokenUntilRefresh(t *testing.T) {
	ecrClient := &countingTokenClient{}
	reconciler := &Reconciler{ECR: ecrClient, RefreshAfter: time.Hour}
	registry := "123456789012.dkr.ecr.us-east-1.amazonaws.com"

	first, err := reconciler.authorization(context.Background(), registry)
	if err != nil {
		t.Fatal(err)
	}
	second, err := reconciler.authorization(context.Background(), registry)
	if err != nil {
		t.Fatal(err)
	}
	if ecrClient.callCount() != 1 {
		t.Fatalf("GetAuthorizationToken calls = %d, want 1", ecrClient.callCount())
	}
	if first.AuthorizationToken == nil || second.AuthorizationToken == nil || *first.AuthorizationToken != *second.AuthorizationToken {
		t.Fatal("expected reconciler to reuse the in-memory authorization token")
	}

	var waitGroup sync.WaitGroup
	for range 8 {
		waitGroup.Go(func() {
			if _, err := reconciler.authorization(context.Background(), registry); err != nil {
				t.Errorf("authorization() error = %v", err)
			}
		})
	}
	waitGroup.Wait()
	if ecrClient.callCount() != 1 {
		t.Fatalf("concurrent GetAuthorizationToken calls = %d, want 1", ecrClient.callCount())
	}

	reconciler.authorizationFetchedAt = time.Now().Add(-2 * time.Hour)
	if _, err := reconciler.authorization(context.Background(), registry); err != nil {
		t.Fatal(err)
	}
	if ecrClient.callCount() != 2 {
		t.Fatalf("GetAuthorizationToken calls after expiry = %d, want 2", ecrClient.callCount())
	}
}
