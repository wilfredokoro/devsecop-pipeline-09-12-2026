ARG RUNTIME_IMAGE
FROM ${RUNTIME_IMAGE}
WORKDIR /app
COPY --chown=10001:10001 target/devsecops-demo.jar /app/app.jar
USER 10001:10001
EXPOSE 8080 8081
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=70.0", "-Djava.io.tmpdir=/tmp", "-jar", "/app/app.jar"]
