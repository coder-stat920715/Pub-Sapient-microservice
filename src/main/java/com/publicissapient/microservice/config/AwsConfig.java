package com.publicissapient.microservice.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.core.client.config.ClientOverrideConfiguration;
import software.amazon.awssdk.core.retry.RetryPolicy;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;

import java.time.Duration;

/**
 * AWS SDK v2 client configuration.
 *
 * DefaultCredentialsProvider resolves credentials in this order at runtime
 * inside ECS Fargate: environment variables -> the ECS container credentials
 * endpoint (backed by the Task Role) -> instance profile. In production this
 * always resolves via the ECS Task Role -- never via static access keys.
 *
 * Because the VPC has Interface/Gateway endpoints for Secrets Manager and S3,
 * these clients reach those services over the AWS private backbone rather
 * than the public internet, even though the SDK code itself is unaware of
 * that routing detail (private DNS makes it transparent).
 */
@Configuration
public class AwsConfig {

    @Value("${aws.region:us-east-1}")
    private String region;

    private ClientOverrideConfiguration defaultOverrideConfig() {
        return ClientOverrideConfiguration.builder()
                .retryPolicy(RetryPolicy.builder()
                        .numRetries(3)
                        .build())
                .apiCallTimeout(Duration.ofSeconds(10))
                .apiCallAttemptTimeout(Duration.ofSeconds(5))
                .build();
    }

    @Bean
    public S3Client s3Client() {
        return S3Client.builder()
                .region(Region.of(region))
                .credentialsProvider(DefaultCredentialsProvider.create())
                .overrideConfiguration(defaultOverrideConfig())
                .build();
    }

    @Bean
    public SecretsManagerClient secretsManagerClient() {
        return SecretsManagerClient.builder()
                .region(Region.of(region))
                .credentialsProvider(DefaultCredentialsProvider.create())
                .overrideConfiguration(defaultOverrideConfig())
                .build();
    }
}
