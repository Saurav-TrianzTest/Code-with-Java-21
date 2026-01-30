package com.codewithjava21.movieapp.cassandraconnect;

import java.net.InetSocketAddress;
import java.nio.file.Paths;
import java.util.List;

import com.datastax.oss.driver.api.core.CqlSession;

public class CassandraConnection {

	private CqlSession cqlSession;
	
	public CassandraConnection(String username, String pwd, List<InetSocketAddress> endpointList, String keyspace, String datacenter) {
        // Connect to open source Apache Cassandra
        try {
        	cqlSession = CqlSession.builder()
                .addContactPoints(endpointList)
                .withAuthCredentials(username, pwd)
                .withKeyspace(keyspace)
                .withLocalDatacenter(datacenter)
                .build();

        	System.out.println("[OK] Success");
        	System.out.printf("[OK] Welcome to Apache Cassandra! Connected to Keyspace %s\n", cqlSession.getKeyspace().get());
        } catch (Exception ex) {
        	System.out.println(ex.getMessage());
        }
	}
	
	public CassandraConnection(String username, String pwd, String secureBundleLocation, String keyspace) {
        // Connect to Astra DB with a secure bundle
        try {
        	// Validate secure bundle path
        	if (secureBundleLocation == null || secureBundleLocation.isEmpty()) {
        		throw new IllegalStateException("Secure bundle location is not configured. Please set ASTRA_DB_SECURE_BUNDLE_PATH environment variable.");
        	}

        	java.nio.file.Path bundlePath = Paths.get(secureBundleLocation);
        	if (!java.nio.file.Files.exists(bundlePath)) {
        		throw new IllegalStateException("Secure bundle file not found at: " + secureBundleLocation + ". Please ensure the file is mounted in the container.");
        	}

        	cqlSession = CqlSession.builder()
                .withCloudSecureConnectBundle(bundlePath)
                .withAuthCredentials(username, pwd)
                .withKeyspace(keyspace)
                .build();

        	System.out.println("[OK] Success");
        	System.out.printf("[OK] Welcome to Astra DB! Connected to Keyspace %s\n", cqlSession.getKeyspace().get());
        } catch (Exception ex) {
        	System.out.println(ex.getMessage());
        }
	}
	
	public CqlSession getCqlSession() {
		return cqlSession;
	}
	
	protected void finalize() {
		System.out.println("[shutdown_driver] Closing connection");
		System.out.println();
		cqlSession.close();
	}
}
