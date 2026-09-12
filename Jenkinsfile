pipeline {
  agent { label 'devsecops-agent' }
  options {
    skipDefaultCheckout(true)
    disableConcurrentBuilds()
    timestamps()
    timeout(time: 150, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '15'))
  }
  parameters {
    booleanParam(name: 'PROMOTE_TO_PRODUCTION', defaultValue: false, description: 'Request approval to promote a passing staging digest')
  }
  stages {
    stage('Checkout') {
      steps {
        deleteDir()
        checkout scm
        sh 'mkdir -p reports .work'
      }
    }
    stage('Secret gate') { steps { sh 'bash scripts/ci.sh secrets' } }
    stage('Compile, test, package, coverage') {
      steps { sh 'bash scripts/ci.sh test' }
      post { always { junit testResults: 'target/surefire-reports/TEST-*.xml', allowEmptyResults: true } }
    }
    stage('Dependency gate') {
      steps {
        withCredentials([string(credentialsId: 'nvd-api-key', variable: 'NVD_API_KEY')]) {
          sh 'bash scripts/ci.sh dependency'
        }
      }
    }
    stage('SonarQube quality gate') {
      steps {
        withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
          sh 'bash scripts/ci.sh sonar'
        }
      }
    }
    stage('Build container') { steps { sh 'bash scripts/ci.sh build' } }
    stage('Image gate and SBOM') { steps { sh 'bash scripts/ci.sh image' } }
    stage('Push candidate') { steps { sh 'bash scripts/ci.sh push' } }
    stage('Deploy staging') { steps { sh 'bash scripts/ci.sh staging' } }
    stage('DAST gate') { steps { sh 'bash scripts/ci.sh dast' } }
    stage('Production approval') {
      when { expression { params.PROMOTE_TO_PRODUCTION } }
      steps {
        timeout(time: 15, unit: 'MINUTES') {
          input message: 'Promote the scanned staging digest to the production lab?', submitter: 'release-manager'
        }
      }
    }
    stage('Production and rollback') {
      when { expression { params.PROMOTE_TO_PRODUCTION } }
      steps { sh 'bash scripts/ci.sh production' }
    }
  }
  post {
    always {
      script {
        if (fileExists('scripts/metrics.py')) {
          withEnv(["PIPELINE_RESULT=${currentBuild.currentResult}", "PIPELINE_DURATION=${(System.currentTimeMillis()-currentBuild.startTimeInMillis)/1000}"]) {
            sh 'python3 scripts/metrics.py update /opt/devsecops/metrics "$PIPELINE_RESULT" "$PIPELINE_DURATION"'
          }
        }
      }
      archiveArtifacts artifacts: 'reports/**,target/site/jacoco/**', allowEmptyArchive: true
    }
    cleanup { sh 'rm -rf .work' }
  }
}
