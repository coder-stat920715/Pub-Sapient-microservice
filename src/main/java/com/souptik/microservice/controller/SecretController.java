package com.souptik.microservice.controller;

import com.souptik.microservice.service.SecretsManagerService;
import jakarta.validation.constraints.NotBlank;
import org.springframework.http.ResponseEntity;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
@RequestMapping("/api/v1/secrets")
@Validated
public class SecretController {

    private final SecretsManagerService secretsManagerService;

    public SecretController(SecretsManagerService secretsManagerService) {
        this.secretsManagerService = secretsManagerService;
    }

    /**
     * Returns metadata about a secret's presence WITHOUT echoing the raw
     * secret value back over HTTP -- a secret value should be consumed
     * internally by the service (e.g. to build a DB connection), never
     * exposed through an API response body.
     */
    @GetMapping("/{secretName}/status")
    public ResponseEntity<Map<String, Object>> checkSecretStatus(
            @PathVariable @NotBlank String secretName) {

        String value = secretsManagerService.getSecretValue(secretName);

        return ResponseEntity.ok(Map.of(
                "secretName", secretName,
                "present", value != null && !value.isBlank(),
                "length", value == null ? 0 : value.length()
        ));
    }
}
