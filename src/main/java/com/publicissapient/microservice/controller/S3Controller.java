package com.publicissapient.microservice.controller;

import com.publicissapient.microservice.service.S3StorageService;
import jakarta.validation.constraints.NotBlank;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
@RequestMapping("/api/v1/files")
@Validated
public class S3Controller {

    private final S3StorageService s3StorageService;

    public S3Controller(S3StorageService s3StorageService) {
        this.s3StorageService = s3StorageService;
    }

    @GetMapping(value = "/{key}", produces = MediaType.TEXT_PLAIN_VALUE)
    public ResponseEntity<String> getFile(@PathVariable @NotBlank String key) {
        String content = s3StorageService.getObjectAsString(key);
        return ResponseEntity.ok(content);
    }

    @PostMapping("/{key}")
    public ResponseEntity<Map<String, String>> putFile(
            @PathVariable @NotBlank String key,
            @RequestBody @NotBlank String content) {

        s3StorageService.putObject(key, content);
        return ResponseEntity.ok(Map.of("key", key, "status", "uploaded"));
    }
}
