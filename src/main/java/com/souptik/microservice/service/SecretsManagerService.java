package com.souptik.microservice.service;

import com.souptik.microservice.exception.ResourceNotFoundException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;
import software.amazon.awssdk.services.secretsmanager.model.GetSecretValueRequest;
import software.amazon.awssdk.services.secretsmanager.model.GetSecretValueResponse;

import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;

/**
 * Reads secrets from AWS Secrets Manager using the IAM Task Role, which is
 * scoped to exactly one secret ARN (see terraform/modules/iam). A short
 * in-memory TTL cache avoids calling Secrets Manager on every request --
 * important both for cost and for the account-level API rate limits.
 */
@Service
public class SecretsManagerService {

    private static final Logger log = LoggerFactory.getLogger(SecretsManagerService.class);
    private static final long CACHE_TTL_MILLIS = TimeUnit.MINUTES.toMillis(5);

    private final SecretsManagerClient secretsManagerClient;

    private final ConcurrentHashMap<String, CachedSecret> cache = new ConcurrentHashMap<>();

    public SecretsManagerService(SecretsManagerClient secretsManagerClient) {
        this.secretsManagerClient = secretsManagerClient;
    }

    public String getSecretValue(String secretName) {
        CachedSecret cached = cache.get(secretName);
        long now = System.currentTimeMillis();

        if (cached != null && (now - cached.fetchedAtMillis) < CACHE_TTL_MILLIS) {
            return cached.value;
        }

        try {
            GetSecretValueRequest request = GetSecretValueRequest.builder()
                    .secretId(secretName)
                    .build();

            GetSecretValueResponse response = secretsManagerClient.getSecretValue(request);
            String value = response.secretString();

            cache.put(secretName, new CachedSecret(value, now));
            log.info("Fetched secret '{}' from Secrets Manager (cache miss)", secretName);
            return value;

        } catch (software.amazon.awssdk.services.secretsmanager.model.ResourceNotFoundException ex) {
            log.warn("Secret '{}' not found in Secrets Manager", secretName);
            throw new ResourceNotFoundException("Secret not found: " + secretName);
        }
    }

    private record CachedSecret(String value, long fetchedAtMillis) {
    }
}
