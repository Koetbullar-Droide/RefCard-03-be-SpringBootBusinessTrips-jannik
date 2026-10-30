package ch.bbw.trips.repo.main;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.CorsRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

@Configuration
public class SpringWebConfig implements WebMvcConfigurer {

	/**
	 * Erlaubte Frontend-Origins, kommagetrennt. Default aus application.properties ("*");
	 * per Umgebungsvariable APP_CORS_ALLOWED_ORIGINS einschränkbar.
	 */
	@Value("${app.cors.allowed-origins}")
	private String[] allowedOrigins;

	/**
	 * CORS - Policy - from known Servers
	 */
	@Override
	public void addCorsMappings(CorsRegistry registry) {
		registry.addMapping("/v1/**")
				.allowedOriginPatterns(allowedOrigins)
				.allowedMethods("GET", "POST", "PUT", "DELETE")
				.allowedHeaders("Authorization", "Content-Type")
				.exposedHeaders("Authorization");
	}
}
