

# Apple Notes MCP Server

Lea y escriba en Apple Notes, con soporte para **formato nativo de Apple Notes**.

[![apple-notes-mcp MCP server](https://glama.ai/mcp/servers/ailenshen/apple-notes-mcp/badges/score.svg)](https://glama.ai/mcp/servers/ailenshen/apple-notes-mcp)

La mayoría de los servidores MCP para Apple Notes solo pueden escribir texto plano. Este crea notas con formato nativo: títulos, encabezados, texto en negrita y listas se renderizan como estilos reales de Apple Notes, no como texto plano. Esto se logra aprovechando la capacidad de importación de Markdown integrada en Notas.app.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/screenshot-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="assets/screenshot-light.png">
  <img alt="Apple Notes MCP" src="assets/screenshot-light.png">
</picture>

**Requiere:** macOS 26 (Tahoe) o posterior, [Node.js](https://nodejs.org/) 24+

## Configuración

### 1. Agregue a su cliente MCP

**Claude Desktop** — edite `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "apple-notes": {
      "command": "npx",
      "args": ["-y", "@ailenshen/apple-notes-mcp@latest"]
    }
  }
}
```

**Claude Code** — ejecute en Terminal:

```bash
claude mcp add apple-notes -- npx -y @ailenshen/apple-notes-mcp@latest
```

### 2. Otorgar permisos

Para admitir el formato nativo, el servidor utiliza la importación de Markdown integrada de Notas.app: abre archivos `.md` con Notas.app y confirma automáticamente el diálogo de importación. Esto requiere dos permisos de macOS para `node`:

| Permiso | Dónde habilitar | Por qué |
|-----------|----------------|-----|
| **Acceso completo al disco** | Ajustes del sistema > Privacidad y seguridad > Acceso completo al disco > habilitar `node` | Leer la base de datos de Notas para listar y buscar |
| **Accesibilidad** | Ajustes del sistema > Privacidad y seguridad > Accesibilidad > habilitar `node` | Confirmar automáticamente el diálogo de importación al crear notas |

Al usarlo por primera vez, macOS le pedirá aprobación; simplemente haga clic en Permitir. Si pasó por alto el aviso, vaya a la configuración anterior y active `node` manualmente. Después de otorgarlo, reinicie su cliente MCP.

> Si falta un permiso, el servidor le indicará exactamente cuál es y cómo solucionarlo.

### 3. Comience a usarlo

Simplemente hable con su IA de forma natural:

- "Lista todas mis notas en la carpeta Proyectos"
- "Busca en mis notas 'agenda de reunión'"
- "Lee mi nota Lista de compras"
- "Crea una nota en Trabajo con los elementos de acción de hoy"
- "Actualiza mi Lista de compras con estos nuevos elementos"
- "Elimina la nota llamada 'Borrador antiguo'"

## ¿Qué puede hacer?

| Herramienta | Descripción |
|------|-------------|
| `list_notes` | Explorar notas, opcionalmente filtrar por carpeta |
| `search_notes` | Buscar notas por palabra clave |
| `get_note` | Leer el contenido completo como Markdown |
| `create_note` | Escribir Markdown → nota con formato nativo |
| `update_note` | Reemplazar contenido, preservando la carpeta |
| `delete_note` | Mover a Eliminados recientemente |

### Soporte de Markdown en Notas

| Elemento | ¿Funciona? |
|---------|--------|
| Encabezados, **negrita**, *cursiva*, listas, `código en línea` | Sí |
| Citas en bloque | Se conserva el contenido, sin estilo de sangría |
| Enlaces | Se conserva el texto, se pierde la URL |
| Tablas, notas al pie | No |

## Acceso remoto (modo HTTP)

¿Desea acceder a sus Apple Notes desde su teléfono u otra computadora?

```bash
npx @ailenshen/apple-notes-mcp@latest --http
```

Esto imprime una URL de punto de conexión con un secreto integrado:

```
Endpoint: http://localhost:3100/mcp/a3f8b2c9e1d4...
```

Dirija su cliente MCP remoto a esta URL. Para acceder a través de Internet, colóquelo detrás de HTTPS usando un túnel (ngrok, Cloudflare Tunnel, etc.).

| Bandera | Predeterminado | Descripción |
|------|---------|-------------|
| `--port <number>` | 3100 | Número de puerto |
| `--secret <string>` | aleatorio | Secreto personalizado de URL |

Para mantenerlo en ejecución entre reinicios, consulte la [wiki](https://github.com/ailenshen/apple-notes-mcp/wiki) para ver un ejemplo de LaunchAgent.

## Cómo funciona

| Acción | Método | Velocidad |
|--------|--------|-------|
| Listar / Buscar | SQLite (solo lectura) | < 100ms |
| Leer | AppleScript → Markdown | ~1s |
| Crear | Importación nativa de Markdown | ~0.5s |
| Actualizar | Eliminar + Crear | ~1.5s |
| Eliminar | AppleScript | ~1s |

- **Lectura** consulta la base de datos de Notas directamente a través de SQLite: rápido y seguro. El contenido se convierte del HTML de Apple a Markdown a través de [turndown](https://github.com/mixmark-io/turndown).
- **Creación** utiliza la importación nativa de Markdown de macOS (`open -a Notes`), por lo que el formato se conserva de forma nativa. Notas.app aparece brevemente (~0,5s) durante la creación.
- **Actualización** elimina la nota antigua y crea una nueva, preservando automáticamente la carpeta original.
- **Eliminación** mueve las notas a Eliminados recientemente, igual que hacerlo manualmente.

## Limitaciones conocidas

- La **edición parcial de notas** (p. ej., "arreglar solo este párrafo") no está admitida. `update_note` siempre reemplaza el contenido completo. Esta es una limitación fundamental de cómo Notas expone el contenido: su interfaz de AppleScript devuelve HTML, no el Markdown original, por lo que hoy no es posible un ciclo limpio de lectura → edición → escritura.
- **Notas aparece brevemente** durante la creación de notas. El flujo de importación de Markdown requiere confirmar automáticamente un diálogo en Notas.app, lo que puede traerla al primer plano momentáneamente.

Estas limitaciones se levantarían si Apple agrega importación/exportación de Markdown a AppleScript, o abre una API oficial de Notas: ambos están en seguimiento para futuras versiones de macOS.

## Visión

Apple Notes es el lugar más natural para guardar el conocimiento personal en dispositivos Apple: se sincroniza en todas partes, es rápido y es privado. Pero es un ecosistema cerrado sin API.

Este proyecto convierte Apple Notes en una fuente de datos de primera clase para la IA. El objetivo a largo plazo: donde sea que hable con la IA, en su Mac, en su teléfono o en la web, sus Apple Notes estén siempre accesibles, legibles y editables.

## Licencia

MIT
