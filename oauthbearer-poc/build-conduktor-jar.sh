#!/bin/bash
set -euo pipefail
#
# build-conduktor-jar.sh
#
# Clones and builds the Conduktor Azure OAUTHBEARER callback handler from source
# as a shaded (fat) JAR including azure-identity and transitive deps.
# Output: oauthbearer-poc/conduktor-azure-oauthbearer.jar
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/../.build/conduktor-azure-oauthbearer"
OUTPUT="${SCRIPT_DIR}/conduktor-azure-oauthbearer.jar"

if [ -f "$OUTPUT" ]; then
  echo "✅ JAR already exists: $OUTPUT"
  echo "   Delete it to force rebuild."
  exit 0
fi

echo "=== Cloning conduktor/azure-kafka-oauthbearer ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
git clone --depth=1 https://github.com/conduktor/azure-kafka-oauthbearer.git "$BUILD_DIR"

echo "=== Adding maven-shade-plugin for fat JAR ==="
cd "$BUILD_DIR"

# Inject shade plugin into the pom.xml before </plugins>
# Use python for cross-platform XML manipulation (works on both macOS and Linux)
python3 -c "
import xml.etree.ElementTree as ET
ET.register_namespace('', 'http://maven.apache.org/POM/4.0.0')
ET.register_namespace('xsi', 'http://www.w3.org/2001/XMLSchema-instance')
tree = ET.parse('pom.xml')
ns = {'m': 'http://maven.apache.org/POM/4.0.0'}
plugins = tree.find('.//m:build/m:plugins', ns)
shade = ET.fromstring('''<plugin xmlns=\"http://maven.apache.org/POM/4.0.0\">
  <groupId>org.apache.maven.plugins</groupId>
  <artifactId>maven-shade-plugin</artifactId>
  <version>3.6.0</version>
  <executions><execution>
    <phase>package</phase>
    <goals><goal>shade</goal></goals>
    <configuration>
      <createDependencyReducedPom>false</createDependencyReducedPom>
      <filters><filter>
        <artifact>*:*</artifact>
        <excludes>
          <exclude>META-INF/*.SF</exclude>
          <exclude>META-INF/*.DSA</exclude>
          <exclude>META-INF/*.RSA</exclude>
        </excludes>
      </filter></filters>
      <transformers>
        <transformer implementation=\"org.apache.maven.plugins.shade.resource.ServicesResourceTransformer\"/>
      </transformers>
    </configuration>
  </execution></executions>
</plugin>''')
plugins.append(shade)
tree.write('pom.xml', xml_declaration=True, encoding='UTF-8')
"

echo "=== Building with Maven (shaded JAR) ==="
mvn package -DskipTests -q

echo "=== Copying JAR ==="
# The shade plugin replaces the original artifact
JAR="target/azure-kafka-oauthbearer-0.7.0-SNAPSHOT.jar"
if [ ! -f "$JAR" ]; then
  JAR=$(find target -maxdepth 1 -name "*.jar" -not -name "*-sources*" -not -name "*-javadoc*" -not -name "original-*" | head -1)
fi

if [ -z "$JAR" ] || [ ! -f "$JAR" ]; then
  echo "❌ No JAR found in target/"
  ls target/*.jar 2>/dev/null
  exit 1
fi

cp "$JAR" "$OUTPUT"
echo "✅ Built: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
