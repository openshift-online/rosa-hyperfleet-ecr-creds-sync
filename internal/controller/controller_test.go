package controller

import (
	"encoding/base64"
	"encoding/json"
	"testing"

	"github.com/aws/aws-sdk-go-v2/service/ecr/types"
)

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
