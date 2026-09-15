package controller

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ecr"
	"github.com/aws/aws-sdk-go-v2/service/ecr/types"
	"github.com/openshift/hypershift/api/hypershift/v1beta1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

type tokenClient interface {
	GetAuthorizationToken(context.Context, *ecr.GetAuthorizationTokenInput, ...func(*ecr.Options)) (*ecr.GetAuthorizationTokenOutput, error)
}

type Reconciler struct {
	client.Client
	ECR          tokenClient
	Repository   string
	RefreshAfter time.Duration
}

func (r *Reconciler) SetupWithManager(mgr manager.Manager, options controller.Options) error {
	return builder.ControllerManagedBy(mgr).WithOptions(options).For(&v1beta1.HostedCluster{}).Complete(r)
}

func (r *Reconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	logger := log.FromContext(ctx).WithValues("hostedCluster", req.NamespacedName)
	var hc v1beta1.HostedCluster
	if err := r.Get(ctx, req.NamespacedName, &hc); err != nil {
		if apierrors.IsNotFound(err) {
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, err
	}
	if !hc.DeletionTimestamp.IsZero() {
		return reconcile.Result{}, nil
	}
	secretName := hc.Spec.PullSecret.Name
	if secretName == "" {
		return reconcile.Result{}, fmt.Errorf("HostedCluster has no spec.pullSecret.name")
	}

	registry, err := registryFromRepository(r.Repository)
	if err != nil {
		return reconcile.Result{}, err
	}
	auth, err := r.authorization(ctx, registry)
	if err != nil {
		return reconcile.Result{}, fmt.Errorf("get ECR authorization token: %w", err)
	}
	secret := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: secretName, Namespace: hc.Namespace}}
	_, err = controllerutil.CreateOrUpdate(ctx, r.Client, secret, func() error {
		secret.Type = corev1.SecretTypeDockerConfigJson
		secret.Data = map[string][]byte{corev1.DockerConfigJsonKey: dockerConfig(registry, auth)}
		return controllerutil.SetControllerReference(&hc, secret, r.Scheme())
	})
	if err != nil {
		return reconcile.Result{}, fmt.Errorf("reconcile pull secret: %w", err)
	}

	logger.Info("reconciled HostedCluster pull secret", "secret", secretName)
	return reconcile.Result{RequeueAfter: r.RefreshAfter}, nil
}

func (r *Reconciler) authorization(ctx context.Context, registry string) (types.AuthorizationData, error) {
	input := &ecr.GetAuthorizationTokenInput{}
	if account := accountFromRegistry(registry); account != "" {
		input.RegistryIds = []string{account}
	}
	output, err := r.ECR.GetAuthorizationToken(ctx, input)
	if err != nil {
		return types.AuthorizationData{}, err
	}
	if len(output.AuthorizationData) == 0 || output.AuthorizationData[0].AuthorizationToken == nil {
		return types.AuthorizationData{}, fmt.Errorf("ECR returned no authorization token")
	}
	return output.AuthorizationData[0], nil
}

func registryFromRepository(repository string) (string, error) {
	value := repository
	if !strings.Contains(value, "://") {
		value = "https://" + value
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Host == "" || parsed.Path == "" || parsed.Path == "/" {
		return "", fmt.Errorf("invalid ECR repository %q", repository)
	}
	return parsed.Host, nil
}

func dockerConfig(registry string, auth types.AuthorizationData) []byte {
	decoded, err := base64.StdEncoding.DecodeString(aws.ToString(auth.AuthorizationToken))
	if err != nil {
		return []byte(`{"auths":{}}`)
	}
	encoded := base64.StdEncoding.EncodeToString(decoded)
	data, _ := json.Marshal(map[string]any{"auths": map[string]map[string]string{registry: {"auth": encoded}}})
	return data
}

var accountPattern = regexp.MustCompile(`^([0-9]{12})\.dkr\.ecr\.`)

func accountFromRegistry(registry string) string {
	match := accountPattern.FindStringSubmatch(registry)
	if len(match) == 2 {
		return match[1]
	}
	return ""
}

var _ client.Object = (*v1beta1.HostedCluster)(nil)
