package main

import (
	"context"
	"flag"
	"os"
	"time"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ecr"
	"github.com/openshift-online/ecr-creds-sync/internal/controller"
	"github.com/openshift/hypershift/api/hypershift/v1beta1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	crcontroller "sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
)

func main() {
	var repository, region string
	flag.StringVar(&repository, "ecr-repository", os.Getenv("ECR_REPOSITORY"), "ECR repository URI, for example 123456789012.dkr.ecr.us-east-1.amazonaws.com/rosa/release")
	flag.StringVar(&region, "aws-region", os.Getenv("AWS_REGION"), "AWS region; when empty, use the AWS SDK region configuration")
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&zap.Options{Development: false})))
	if repository == "" {
		ctrl.Log.Error(nil, "ecr-repository is required")
		os.Exit(2)
	}

	ctx := context.Background()
	loadOptions := []func(*config.LoadOptions) error{}
	if region != "" {
		loadOptions = append(loadOptions, config.WithRegion(region))
	}
	awsConfig, err := config.LoadDefaultConfig(ctx, loadOptions...)
	if err != nil {
		ctrl.Log.Error(err, "unable to load AWS configuration")
		os.Exit(1)
	}

	scheme := runtime.NewScheme()
	_ = clientgoscheme.AddToScheme(scheme)
	_ = v1beta1.AddToScheme(scheme)
	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{Scheme: scheme, HealthProbeBindAddress: ":8081"})
	if err != nil {
		ctrl.Log.Error(err, "unable to start manager")
		os.Exit(1)
	}

	r := &controller.Reconciler{
		Client:       mgr.GetClient(),
		ECR:          ecr.NewFromConfig(awsConfig),
		Repository:   repository,
		RefreshAfter: 10 * time.Hour,
	}
	if err := r.SetupWithManager(mgr, crcontroller.Options{MaxConcurrentReconciles: 4}); err != nil {
		ctrl.Log.Error(err, "unable to create controller")
		os.Exit(1)
	}
	_ = mgr.AddHealthzCheck("health", healthz.Ping)
	_ = mgr.AddReadyzCheck("ready", healthz.Ping)
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		ctrl.Log.Error(err, "manager stopped")
		os.Exit(1)
	}
}
