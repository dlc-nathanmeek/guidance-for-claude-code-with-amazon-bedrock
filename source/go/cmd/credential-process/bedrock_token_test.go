package main

// ABOUTME: Regression test for generateBedrockToken's SigV4 payload hash.
// ABOUTME: The canonical request must hash the empty body (SHA-256 of ""), NOT the
// ABOUTME: literal "UNSIGNED-PAYLOAD" — otherwise Bedrock's CallWithBearerToken
// ABOUTME: validator recomputes a different signature and returns 403
// ABOUTME: "Authentication failed: Please make sure your API Key is valid."

import (
	"encoding/base64"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"testing"
)

// recomputeSignature rebuilds the SigV4 signature over the token's own query
// parameters, using the supplied payload-hash literal for the canonical request.
// It mirrors generateBedrockToken's signing steps exactly so we can prove which
// payload hash the emitted signature was actually computed with.
func recomputeSignature(t *testing.T, params url.Values, secretAccessKey, region, payloadHash string) string {
	t.Helper()

	amzDate := params.Get("X-Amz-Date")
	dateStamp := amzDate[:8] // YYYYMMDD

	// Canonical query: every signed param except the signature itself, sorted.
	signed := url.Values{}
	for k, v := range params {
		if k == "X-Amz-Signature" || k == "Version" {
			continue
		}
		signed[k] = v
	}
	sortedKeys := make([]string, 0, len(signed))
	for k := range signed {
		sortedKeys = append(sortedKeys, k)
	}
	sort.Strings(sortedKeys)

	var canonicalQuery strings.Builder
	for i, k := range sortedKeys {
		if i > 0 {
			canonicalQuery.WriteByte('&')
		}
		canonicalQuery.WriteString(url.QueryEscape(k))
		canonicalQuery.WriteByte('=')
		canonicalQuery.WriteString(url.QueryEscape(signed.Get(k)))
	}

	canonicalRequest := fmt.Sprintf("POST\n/\n%s\nhost:%s\n\nhost\n%s",
		canonicalQuery.String(), bedrockHost, payloadHash)

	stringToSign := fmt.Sprintf("AWS4-HMAC-SHA256\n%s\n%s/%s/%s/aws4_request\n%s",
		amzDate, dateStamp, region, bedrockService, sha256Hex(canonicalRequest))

	signingKey := deriveSigningKey(secretAccessKey, dateStamp, region, bedrockService)
	return hmacSHA256Hex(signingKey, stringToSign)
}

// decodeTokenParams strips the "bedrock-api-key-" prefix, base64-decodes the
// presigned URL, and returns its query parameters.
func decodeTokenParams(t *testing.T, token string) url.Values {
	t.Helper()

	if !strings.HasPrefix(token, authPrefix) {
		t.Fatalf("token missing %q prefix: %q", authPrefix, token)
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(token, authPrefix))
	if err != nil {
		t.Fatalf("base64 decode failed: %v", err)
	}
	decoded := string(raw)
	q := decoded[strings.Index(decoded, "?")+1:]
	params, err := url.ParseQuery(q)
	if err != nil {
		t.Fatalf("parse query failed: %v", err)
	}
	return params
}

// TestGenerateBedrockTokenUsesEmptyPayloadHash is the regression guard for the
// 403 "API Key is valid" failure. The emitted signature must match a canonical
// request built with the empty-body SHA-256 hash, and must NOT match one built
// with the "UNSIGNED-PAYLOAD" literal (the shipped bug). Session token includes
// '/', '+', '=' to keep the canonical-query encoding exercised.
func TestGenerateBedrockTokenUsesEmptyPayloadHash(t *testing.T) {
	const (
		accessKeyID     = "ASIAEXAMPLEEXAMPLE00"
		secretAccessKey = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY00"
		sessionToken    = "FQoGZXIvYXdzEID//////////wEaDExAMPLE+token/with=slashes+plus=eq"
		region          = "us-east-2"
	)

	token, err := generateBedrockToken(accessKeyID, secretAccessKey, sessionToken, region)
	if err != nil {
		t.Fatalf("generateBedrockToken returned error: %v", err)
	}

	params := decodeTokenParams(t, token)
	emitted := params.Get("X-Amz-Signature")
	if emitted == "" {
		t.Fatal("token has no X-Amz-Signature")
	}

	emptyBodyHash := sha256Hex("") // e3b0c442…b855
	wantValid := recomputeSignature(t, params, secretAccessKey, region, emptyBodyHash)
	wantBuggy := recomputeSignature(t, params, secretAccessKey, region, "UNSIGNED-PAYLOAD")

	if emitted != wantValid {
		t.Errorf("signature not computed over empty-body payload hash\n emitted = %s\n want    = %s",
			emitted, wantValid)
	}
	if emitted == wantBuggy {
		t.Error("signature was computed with the UNSIGNED-PAYLOAD literal — Bedrock will reject with 403 " +
			`"Authentication failed: Please make sure your API Key is valid."`)
	}
}

// TestGenerateBedrockTokenRequiresCredentials keeps the input-validation contract.
func TestGenerateBedrockTokenRequiresCredentials(t *testing.T) {
	cases := []struct{ name, ak, sk, region string }{
		{"missing access key", "", "sk", "us-east-2"},
		{"missing secret", "ak", "", "us-east-2"},
		{"missing region", "ak", "sk", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := generateBedrockToken(tc.ak, tc.sk, "", tc.region); err == nil {
				t.Error("expected error for missing required input, got nil")
			}
		})
	}
}
