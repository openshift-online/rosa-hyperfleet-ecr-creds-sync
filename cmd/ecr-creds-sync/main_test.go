package main

import (
	"testing"
	"time"
)

func TestRefreshAfterFromEnv(t *testing.T) {
	tests := []struct {
		name    string
		value   string
		want    time.Duration
		wantErr bool
	}{
		{name: "default", want: 2 * time.Hour},
		{name: "configured", value: "30m", want: 30 * time.Minute},
		{name: "invalid", value: "not-a-duration", wantErr: true},
		{name: "zero", value: "0", wantErr: true},
		{name: "negative", value: "-1m", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := refreshAfterFromEnv(tt.value)
			if (err != nil) != tt.wantErr {
				t.Fatalf("refreshAfterFromEnv() error = %v, wantErr %v", err, tt.wantErr)
			}
			if !tt.wantErr && got != tt.want {
				t.Fatalf("refreshAfterFromEnv() = %s, want %s", got, tt.want)
			}
		})
	}
}
