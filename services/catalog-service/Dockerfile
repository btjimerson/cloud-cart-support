FROM maven:3.9.10-eclipse-temurin-21 AS build
COPY pom.xml /home/pom.xml
RUN mvn -f /home/pom.xml install -N
# Path must mirror the repo: catalog-service/pom.xml resolves its parent via ../../pom.xml
COPY services/catalog-service/pom.xml /home/services/catalog-service/pom.xml
COPY services/catalog-service/src /home/services/catalog-service/src
RUN mvn -f /home/services/catalog-service/pom.xml clean package -DskipTests

FROM eclipse-temurin:21-jre
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
RUN useradd -r -u 1001 appuser
WORKDIR /opt
EXPOSE 8080
COPY --from=build /home/services/catalog-service/target/*.jar /opt/app.jar
USER appuser
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s --retries=3 \
  CMD curl -f http://localhost:8080/actuator/health || exit 1
CMD ["java", "-jar", "/opt/app.jar"]
