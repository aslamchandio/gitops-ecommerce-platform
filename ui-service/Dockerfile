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
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-Dspring.thymeleaf.cache=true", "-jar", "/app/app.jar"]
