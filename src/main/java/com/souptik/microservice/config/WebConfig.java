package com.souptik.microservice.config;

import org.springframework.boot.web.embedded.tomcat.TomcatServletWebServerFactory;
import org.springframework.boot.web.server.WebServerFactoryCustomizer;
import org.springframework.context.annotation.Configuration;

/**
 * Tunes the embedded Tomcat connector for container deployment:
 *  - connectionTimeout bounds slow/stalled clients so worker threads are
 *    reclaimed promptly (important with a small container CPU allocation).
 */
@Configuration
public class WebConfig implements WebServerFactoryCustomizer<TomcatServletWebServerFactory> {

    @Override
    public void customize(TomcatServletWebServerFactory factory) {
        factory.addConnectorCustomizers(connector -> {
            connector.setProperty("connectionTimeout", "20000");
        });
    }
}
