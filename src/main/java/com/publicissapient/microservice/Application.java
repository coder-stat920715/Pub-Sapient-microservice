package com.publicissapient.microservice;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Entry point for the microservice.
 *
 * Graceful shutdown (server.shutdown=graceful in application.yml) is what
 * allows this application to cooperate correctly with ECS during a
 * deployment or scale-in event:
 *
 *  1. ECS marks the task as DRAINING and the ALB stops sending new requests
 *     to it (target deregistration_delay covers this).
 *  2. ECS sends SIGTERM to the container's PID 1.
 *  3. Spring's graceful shutdown intercepts SIGTERM, stops accepting new
 *     requests on the embedded Tomcat connector, and waits (up to
 *     spring.lifecycle.timeout-per-shutdown-phase) for in-flight requests
 *     to complete before the JVM exits.
 *  4. If the app hasn't exited within ecs task stopTimeout, ECS sends
 *     SIGKILL. stopTimeout in the task definition is intentionally set
 *     higher than the Spring shutdown timeout so graceful shutdown always
 *     wins the race.
 */
@SpringBootApplication
public class Application {

    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }
}
