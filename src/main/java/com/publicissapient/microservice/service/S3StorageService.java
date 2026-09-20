package com.publicissapient.microservice.service;

import com.publicissapient.microservice.exception.ResourceNotFoundException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import software.amazon.awssdk.core.ResponseInputStream;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.GetObjectResponse;
import software.amazon.awssdk.services.s3.model.NoSuchKeyException;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import software.amazon.awssdk.services.s3.model.PutObjectResponse;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;

/**
 * Reads/writes objects in exactly one S3 bucket -- the bucket ARN the Task
 * Role's IAM policy grants access to (terraform/modules/iam). Any attempt to
 * address a different bucket at runtime would be rejected by IAM with an
 * AccessDenied error before it ever touched application logic, because the
 * policy has no wildcard across bucket names.
 */
@Service
public class S3StorageService {

    private static final Logger log = LoggerFactory.getLogger(S3StorageService.class);

    private final S3Client s3Client;
    private final String bucketName;

    public S3StorageService(S3Client s3Client,
                             @Value("${app.s3-bucket-name}") String bucketName) {
        this.s3Client = s3Client;
        this.bucketName = bucketName;
    }

    public String getObjectAsString(String key) {
        GetObjectRequest request = GetObjectRequest.builder()
                .bucket(bucketName)
                .key(key)
                .build();

        try (ResponseInputStream<GetObjectResponse> response = s3Client.getObject(request)) {
            byte[] bytes = response.readAllBytes();
            log.info("Fetched object '{}' ({} bytes) from bucket '{}'", key, bytes.length, bucketName);
            return new String(bytes, StandardCharsets.UTF_8);
        } catch (NoSuchKeyException ex) {
            log.warn("Object '{}' not found in bucket '{}'", key, bucketName);
            throw new ResourceNotFoundException("Object not found: " + key);
        } catch (IOException ex) {
            throw new UncheckedIOException("Failed reading object stream for key: " + key, ex);
        }
    }

    public void putObject(String key, String content) {
        PutObjectRequest request = PutObjectRequest.builder()
                .bucket(bucketName)
                .key(key)
                .contentType("text/plain")
                .build();

        PutObjectResponse response = s3Client.putObject(
                request,
                RequestBody.fromString(content, StandardCharsets.UTF_8)
        );

        log.info("Uploaded object '{}' to bucket '{}' (eTag={})", key, bucketName, response.eTag());
    }
}
