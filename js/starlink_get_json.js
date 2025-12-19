const puppeteer = require('puppeteer-core');

/**
 * Starlink Diagnostics Collector
 * 
 * Connects to local Starlink router and extracts diagnostic JSON data
 * Returns structured JSON output or exits with error code
 */

// Configuration
const STARLINK_URL = 'http://192.168.100.1/';
const BROWSER_PATH = '/usr/bin/chromium-browser';
const TIMEOUT = 20000;
const SELECTOR_TIMEOUT = 10000;

// Exit codes
const EXIT_SUCCESS = 0;
const EXIT_CONNECTION_FAILED = 1;
const EXIT_SELECTOR_NOT_FOUND = 2;
const EXIT_NO_DATA = 3;
const EXIT_UNKNOWN_ERROR = 4;

/**
 * Main execution
 */
(async () => {
    let browser = null;
    
    try {
        // Launch browser
        browser = await puppeteer.launch({
            headless: true,
            executablePath: BROWSER_PATH,
            args: [
                '--no-sandbox',
                '--disable-setuid-sandbox',
                '--disable-dev-shm-usage',
                '--disable-accelerated-2d-canvas',
                '--disable-gpu'
            ]
        });
        
        // Create new page
        const page = await browser.newPage();
        
        // Set timeout for navigation
        page.setDefaultTimeout(TIMEOUT);
        
        // Navigate to Starlink diagnostics page
        await page.goto(STARLINK_URL, {
            waitUntil: 'networkidle2',
            timeout: TIMEOUT
        });
        
        // Wait for JSON data selector
        await page.waitForSelector('.Json-Text', {
            timeout: SELECTOR_TIMEOUT
        });
        
        // Extract JSON text
        const jsonText = await page.$eval('.Json-Text', el => el.innerText);
        
        // Verify we got data
        if (!jsonText || jsonText.trim().length === 0) {
            console.error('ERROR: No JSON data extracted');
            await browser.close();
            process.exit(EXIT_NO_DATA);
        }
        
        // Output JSON (will be captured by bash script)
        console.log(jsonText);
        
        // Clean exit
        await browser.close();
        process.exit(EXIT_SUCCESS);
        
    } catch (error) {
        // Log error with type
        if (error.message.includes('net::ERR')) {
            console.error('ERROR: Network connection failed -', error.message);
            if (browser) await browser.close();
            process.exit(EXIT_CONNECTION_FAILED);
        } else if (error.message.includes('waiting for selector')) {
            console.error('ERROR: Selector not found -', error.message);
            if (browser) await browser.close();
            process.exit(EXIT_SELECTOR_NOT_FOUND);
        } else {
            console.error('ERROR: Unknown error -', error.message);
            if (browser) await browser.close();
            process.exit(EXIT_UNKNOWN_ERROR);
        }
    }
})();
