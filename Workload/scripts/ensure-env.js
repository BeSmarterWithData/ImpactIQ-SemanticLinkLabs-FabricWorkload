#!/usr/bin/env node

/**
 * Ensure .env.dev file exists before starting development server
 * If it doesn't exist, create it from .env.template with default values
 */

const fs = require('fs');
const path = require('path');

const workloadDir = path.resolve(__dirname, '..');
const envDevPath = path.join(workloadDir, '.env.dev');
const envTemplatePath = path.join(workloadDir, '.env.template');

// Check if .env.dev already exists
if (fs.existsSync(envDevPath)) {
    console.log('✅ .env.dev file already exists');
    process.exit(0);
}

// Check if template exists
if (!fs.existsSync(envTemplatePath)) {
    console.error('❌ Error: .env.template file not found');
    console.error('Please ensure .env.template exists in the Workload directory');
    process.exit(1);
}

// Read template content
let templateContent = fs.readFileSync(envTemplatePath, 'utf8');

// Replace placeholders with default development values
templateContent = templateContent
    .replace('<YOUR_ENTRA_APP_ID>', '00000000-0000-0000-0000-000000000000');

// Write .env.dev file
fs.writeFileSync(envDevPath, templateContent, 'utf8');

console.log('✅ Created .env.dev file from template with default development values');
console.log('📝 Note: For production use, update FRONTEND_APPID in .env.dev with your actual Entra App ID');
console.log('   To run the full setup wizard with Entra app creation:');
console.log('   cd ../scripts/Setup && pwsh ./Setup.ps1');
