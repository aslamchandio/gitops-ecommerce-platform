# ---- build ----
FROM maven:3.9-eclipse-temurin-21 AS builder
WORKDIR /src
COPY pom.xml ./
RUN mvn -B dependency:go-offline
COPY src ./src
RUN mvn -B -DskipTests package

# ---- runtime ----
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=builder /src/target/ui-service-*.jar /app/app.jar
# Build SHA baked into the image so the running app can advertise its version
# as a cache-busting query (?v=<sha>) on static asset links. Falls back to
# 'dev' for local compose builds where the arg is not provided.
ARG GIT_SHA=dev
ENV APP_VERSION=${GIT_SHA}
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-Dspring.thymeleaf.cache=true", "-jar", "/app/app.jar"]
