import re
import urllib.request
import xml.etree.ElementTree as ET
items = {
    'BOOT_VERSION': ('org/springframework/boot/spring-boot-starter-parent', r'3\.5\.\d+'),
    'JACOCO_VERSION': ('org/jacoco/jacoco-maven-plugin', r'0\.8\.\d+'),
    'ODC_VERSION': ('org/owasp/dependency-check-maven', r'\d+\.\d+\.\d+'),
    'SONAR_SCANNER_VERSION': ('org/sonarsource/scanner/maven/sonar-maven-plugin', r'\d+(?:\.\d+){2,3}')
}
for name, (path, pattern) in items.items():
    with urllib.request.urlopen('https://repo.maven.apache.org/maven2/'+path+'/maven-metadata.xml', timeout=60) as response:
        document=ET.fromstring(response.read())
    versions=[e.text for e in document.findall('./versioning/versions/version') if re.fullmatch(pattern,e.text or '')]
    if not versions: raise RuntimeError('No stable version found for '+name)
    value=max(versions,key=lambda v:tuple(map(int,v.split('.'))))
    print(name+'='+value)
