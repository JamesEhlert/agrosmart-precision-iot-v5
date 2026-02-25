// ARQUIVO: lib/core/config/app_config.dart

class AppConfig {
  // Lê a variável passada pelo terminal durante a compilação/execução.
  // Se não for passada, usa uma string vazia (ou você pode colocar a URL de DEV como fallback).
  static const String apiBaseUrl = String.fromEnvironment(
    'AGROSMART_API_BASE_URL',
    defaultValue: '', 
  );

  static String get telemetryEndpoint => '$apiBaseUrl/telemetry';
  static String get commandEndpoint => '$apiBaseUrl/command';
}