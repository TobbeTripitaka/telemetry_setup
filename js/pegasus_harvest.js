const puppeteer = require('puppeteer-core');
const fs = require('fs');
const path = require('path');

// ---- Button and Input Selectors ----
const ALL_BTN = '#allBtn';
const SINCE_LAST_BTN = '#sincelastBtn';
const DATE_RANGE_BTN = '#customBtn';
const FROM_DATE_INPUT = '#mat-input-2';
const TO_DATE_INPUT = '#mat-input-3';
const START_HARVEST_BTN = '.ctl-btn'; // Using class selector with tooltip "Start harvesting"

// ---- Configurable Timings and Arguments ----
const delayAllClick = 1000;
const delayOpenConfig = 1200;
const delaySetOutputDir = 800;
const delaySaveConfig = 1200;
const delayHarvestClick = 1000;
const delayHarvestDialogWait = 2000;
const maxHarvestWait = 180000; // 3 minutes timeout for each attempt
const retryDelay = 4000;
const progressCheckInterval = 5000; // Check progress every 5 seconds
const maxNoProgressChecks = 6; // 30 seconds of no progress = frozen
const browserConnectRetries = 3;

const args = process.argv;
const harvestDir = args[2];
const execute = args[3];
const waitTime = parseFloat(args[4]);
const afterWait = args[5];
const harvestMode = args[6];
const fromDate = args[7] || '2025-10-01 00:00:00';
const toDate = args[8] || '2050-01-01 23:59:59';

// Enhanced logging class for structured logging
class HarvestLogger {
    constructor() {
        this.startTime = Date.now();
        this.attemptLogs = [];
    }
    
    logAttempt(mode, attemptNum, result, duration) {
        const logEntry = {
            mode,
            attemptNum,
            result,
            duration,
            timestamp: new Date().toISOString()
        };
        this.attemptLogs.push(logEntry);
        
        logWithTimestamp(`[${mode.toUpperCase()}:${attemptNum}] ${result} (${duration}ms)`);
    }
    
    generateSummaryReport() {
        const totalDuration = Date.now() - this.startTime;
        const summary = {
            totalDuration,
            totalAttempts: this.attemptLogs.length,
            successfulModes: this.attemptLogs.filter(log => log.result === 'SUCCESS'),
            failedModes: this.attemptLogs.filter(log => log.result === 'FAILED')
        };
        
        logWithTimestamp(`HARVEST SUMMARY: ${summary.successfulModes.length} successful, ${summary.failedModes.length} failed, ${totalDuration}ms total`);
        return summary;
    }
}

const logger = new HarvestLogger();

// Enhanced logging function
function logWithTimestamp(message) {
    const timestamp = new Date().toISOString();
    console.log(`${timestamp} - ${message}`);
}

// Exit with proper code
function exitWithError(message, code = 1) {
    logWithTimestamp(`FATAL ERROR: ${message}`);
    logger.generateSummaryReport();
    process.exit(code);
}

function exitWithSuccess(message) {
    logWithTimestamp(`SUCCESS: ${message}`);
    logger.generateSummaryReport();
    process.exit(0);
}

// Enhanced browser connection with retry logic
async function connectToBrowserWithRetry(maxRetries = browserConnectRetries) {
    for (let attempt = 1; attempt <= maxRetries; attempt++) {
        try {
            logWithTimestamp(`Attempting browser connection (${attempt}/${maxRetries})`);
            
            const browser = await puppeteer.connect({
                browserURL: 'http://localhost:9222',
                defaultViewport: null,
                slowMo: 50 // Add slight delay for stability
            });
            
            // Verify connection is actually working
            const pages = await browser.pages();
            if (pages.length === 0) {
                throw new Error("No pages available in browser session");
            }
            
            // Test page responsiveness
            const page = pages[0];
            await page.evaluate(() => document.readyState);
            
            logWithTimestamp(`Browser connection successful on attempt ${attempt}`);
            return browser;
            
        } catch (error) {
            logWithTimestamp(`Browser connection attempt ${attempt} failed: ${error.message}`);
            if (attempt < maxRetries) {
                logWithTimestamp(`Waiting 5 seconds before retry...`);
                await new Promise(resolve => setTimeout(resolve, 5000));
            }
        }
    }
    throw new Error(`Failed to connect to browser after ${maxRetries} attempts`);
}

// Configuration validation
function validateHarvestConfig() {
    const issues = [];
    
    if (!harvestDir || harvestDir.length === 0) {
        issues.push("Harvest directory not specified");
    }
    
    try {
        if (!fs.existsSync(path.dirname(harvestDir))) {
            issues.push("Parent directory of harvest path does not exist");
        }
    } catch (e) {
        issues.push("Invalid harvest directory path");
    }
    
    // Validate date format and logic
    if (harvestMode === 'date range') {
        try {
            const from = new Date(fromDate);
            const to = new Date(toDate);
            if (isNaN(from.getTime()) || isNaN(to.getTime())) {
                issues.push("Invalid date format");
            } else if (from >= to) {
                issues.push("From date must be before to date");
            } else if (to > new Date()) {
                logWithTimestamp("WARNING: To date is in the future");
            }
        } catch (e) {
            issues.push("Date parsing error");
        }
    }
    
    if (issues.length > 0) {
        logWithTimestamp("Configuration validation issues:");
        issues.forEach(issue => logWithTimestamp(`  - ${issue}`));
        return false;
    }
    
    logWithTimestamp("Configuration validation passed");
    return true;
}

// System resource monitoring
async function monitorSystemResources() {
    try {
        const memUsage = process.memoryUsage();
        const memMB = Math.round(memUsage.heapUsed / 1024 / 1024);
        
        logWithTimestamp(`Memory usage: ${memMB}MB`);
        
        if (memUsage.heapUsed > 1024 * 1024 * 500) { // 500MB
            logWithTimestamp("WARNING: High memory usage detected");
        }
        
        // Check disk space if harvest directory exists
        if (fs.existsSync(path.dirname(harvestDir))) {
            const stats = fs.statSync(path.dirname(harvestDir));
            logWithTimestamp("Disk space check completed");
        }
        
    } catch (error) {
        logWithTimestamp(`Resource monitoring: ${error.message}`);
    }
}

// Check if harvest directory has data files
function checkForHarvestedData(directory) {
    try {
        if (!fs.existsSync(directory)) {
            logWithTimestamp(`Directory does not exist: ${directory}`);
            return false;
        }
        
        const files = fs.readdirSync(directory);
        const dataFiles = files.filter(file => {
            const filePath = path.join(directory, file);
            const stats = fs.statSync(filePath);
            return stats.isFile() && stats.size > 0;
        });
        
        logWithTimestamp(`Found ${dataFiles.length} data files in ${directory}`);
        return dataFiles.length > 0;
    } catch (error) {
        logWithTimestamp(`Error checking directory ${directory}: ${error.message}`);
        return false;
    }
}

// ---- Main Puppeteer Automation ----
(async () => {
    let browser;
    
    try {
        logWithTimestamp("Starting enhanced Pegasus harvest automation");
        logWithTimestamp(`Target output directory: ${harvestDir}`);
        logWithTimestamp(`Initial harvest mode: ${harvestMode}`);
        logWithTimestamp(`Date range: ${fromDate} to ${toDate}`);
        
        // Validate configuration before starting
        if (!validateHarvestConfig()) {
            exitWithError("Configuration validation failed");
        }
        
        // Monitor system resources
        await monitorSystemResources();
        
        // Enhanced browser connection with retry
        browser = await connectToBrowserWithRetry();
        
        const [page] = await browser.pages();
        if (!page) {
            exitWithError("No pages available in browser");
        }
        
        logWithTimestamp("Connected to Pegasus Harvester browser session");
        
        // Harvest attempt sequence with fallback modes
        const harvestModes = [
            harvestMode,           // First attempt: use config mode
            harvestMode,           // Second attempt: retry same mode
            'date range',          // Third attempt: date range with config dates
            'all'                  // Final attempt: all data
        ];
        
        let harvestSucceeded = false;
        let attemptNumber = 0;
        
        for (const currentMode of harvestModes) {
            attemptNumber++;
            const attemptStartTime = Date.now();
            logWithTimestamp(`\n=== ATTEMPT ${attemptNumber}: Using harvest mode '${currentMode}' ===`);
            
            // Execute automation for current mode with enhanced error handling
            const result = await page.evaluate(async ({
                delayAllClick,
                delayOpenConfig,
                delaySetOutputDir,
                delaySaveConfig,
                delayHarvestClick,
                delayHarvestDialogWait,
                maxHarvestWait,
                retryDelay,
                progressCheckInterval,
                maxNoProgressChecks,
                harvestDir,
                fromDate,
                toDate,
                currentMode,
                ALL_BTN,
                SINCE_LAST_BTN,
                DATE_RANGE_BTN,
                FROM_DATE_INPUT,
                TO_DATE_INPUT,
                START_HARVEST_BTN
            }) => {
                function sleep(ms) {
                    return new Promise(resolve => setTimeout(resolve, ms));
                }
                
                // Enhanced UI state verification
                async function verifyUIState() {
                    console.log("Verifying UI state...");
                    
                    // Check for error dialogs
                    const errorDialog = document.querySelector('.error-dialog, [role="alertdialog"]');
                    if (errorDialog) {
                        console.log("Error dialog detected, attempting to close");
                        const closeBtn = errorDialog.querySelector('button');
                        if (closeBtn) closeBtn.click();
                        await sleep(1000);
                    }
                    
                    // Check for loading states
                    const loadingElements = document.querySelectorAll('.loading, .spinner, mat-spinner');
                    if (loadingElements.length > 0) {
                        console.log("Loading state detected, waiting...");
                        let waitCount = 0;
                        while (document.querySelectorAll('.loading, .spinner, mat-spinner').length > 0 && waitCount < 10) {
                            await sleep(1000);
                            waitCount++;
                        }
                    }
                    
                    // Verify start button availability
                    const startBtn = document.querySelector('[mattooltip="Start harvesting"]');
                    if (!startBtn) {
                        throw new Error("Start harvesting button not found - UI may not be ready");
                    }
                    
                    console.log("UI state verification passed");
                    return true;
                }
                
                // Robust element finding with multiple strategies
                async function findDateInputs() {
                    console.log("Looking for date input fields with multiple strategies...");
                    
                    const strategies = [
                        // Strategy 1: Direct ID selection
                        () => {
                            const from = document.querySelector(FROM_DATE_INPUT);
                            const to = document.querySelector(TO_DATE_INPUT);
                            return from && to ? [from, to] : null;
                        },
                        // Strategy 2: By placeholder text
                        () => {
                            const from = document.querySelector('input[placeholder*="from" i], input[placeholder*="start" i]');
                            const to = document.querySelector('input[placeholder*="to" i], input[placeholder*="end" i]');
                            return from && to ? [from, to] : null;
                        },
                        // Strategy 3: By date type
                        () => {
                            const dateInputs = Array.from(document.querySelectorAll('input[type="date"], input[type="datetime-local"]'));
                            return dateInputs.length >= 2 ? [dateInputs[0], dateInputs[1]] : null;
                        },
                        // Strategy 4: By Angular Material components
                        () => {
                            const matInputs = Array.from(document.querySelectorAll('mat-datepicker-input, input[matdatepicker]'));
                            return matInputs.length >= 2 ? [matInputs[0], matInputs[1]] : null;
                        }
                    ];
                    
                    for (let i = 0; i < strategies.length; i++) {
                        try {
                            const result = strategies[i]();
                            if (result) {
                                console.log(`Found date inputs using strategy ${i + 1}`);
                                return result;
                            }
                        } catch (e) {
                            console.log(`Strategy ${i + 1} failed: ${e.message}`);
                        }
                    }
                    
                    throw new Error("Could not locate date input fields with any strategy");
                }
                
                function clickButtonByText(text, strict = true) {
                    const btn = Array.from(document.querySelectorAll('button')).find(
                        b => strict
                            ? b.textContent.trim().toLowerCase() === text.toLowerCase()
                            : b.textContent.trim().toLowerCase().includes(text.toLowerCase())
                    );
                    if (btn && !btn.disabled) {
                        btn.click();
                        console.log(`Clicked "${btn.textContent.trim()}" button`);
                        return true;
                    }
                    return false;
                }
                
                async function setOutputDirectory(path) {
                    let dialog = document.querySelector('[role="dialog"]') ||
                        document.querySelector('.mat-dialog-container');
                    if (!dialog) {
                        console.warn("Archive Configuration dialog not found");
                        return false;
                    }
                    
                    let outputInputs = Array.from(dialog.querySelectorAll('input[type="text"]'));
                    let outputInput = outputInputs[0];
                    if (outputInput) {
                        outputInput.focus();
                        outputInput.value = path;
                        outputInput.dispatchEvent(new Event('input', { bubbles: true }));
                        outputInput.dispatchEvent(new Event('change', { bubbles: true }));
                        console.log(`Set Output Directory: ${path}`);
                        
                        // Verify the value was set
                        await sleep(500);
                        if (outputInput.value !== path) {
                            console.warn(`Output directory verification failed: expected "${path}", got "${outputInput.value}"`);
                        }
                        
                        return true;
                    }
                    console.warn("Could not find Output Directory input field in dialog");
                    return false;
                }
                
                // Enhanced progress monitoring with harvest-specific validation
                function isHarvestProgress(element) {
                    // Validate this is actually harvest progress, not other UI percentages
                    const parent = element.closest('.harvest-container, .progress-container, mat-progress-bar, .mat-progress-bar');
                    const textContent = (element.parentElement?.textContent || '').toLowerCase();
                    
                    // Look for harvest-related context
                    const harvestKeywords = ['harvest', 'download', 'export', 'processing', 'files', 'progress'];
                    const hasHarvestContext = harvestKeywords.some(keyword => 
                        textContent.includes(keyword)
                    );
                    
                    // Exclude common non-harvest percentages
                    const excludeKeywords = ['battery', 'cpu', 'memory', 'disk', 'volume'];
                    const hasExcludeContext = excludeKeywords.some(keyword =>
                        textContent.includes(keyword)
                    );
                    
                    return (parent !== null || hasHarvestContext) && !hasExcludeContext;
                }
                
                async function detectProgressMultiStrategy() {
                    // Strategy 1: Look for percentage in progress bars
                    const progressBars = document.querySelectorAll('mat-progress-bar, .progress-bar, [role="progressbar"]');
                    for (const bar of progressBars) {
                        const percentText = bar.textContent.match(/(\d+)%/);
                        if (percentText && isHarvestProgress(bar)) {
                            return {
                                percentage: parseInt(percentText[1]),
                                source: 'progress-bar',
                                element: bar
                            };
                        }
                    }
                    
                    // Strategy 2: Look for percentage anywhere in harvest-related containers
                    const allElements = Array.from(document.querySelectorAll('*')).filter(el => {
                        if (!el.textContent) return false;
                        const match = el.textContent.match(/(\d+)%/);
                        return match && isHarvestProgress(el);
                    });
                    
                    if (allElements.length > 0) {
                        const match = allElements[0].textContent.match(/(\d+)%/);
                        return {
                            percentage: parseInt(match[1]),
                            source: 'text-content',
                            element: allElements[0]
                        };
                    }
                    
                    return {
                        percentage: null,
                        source: 'none',
                        element: null
                    };
                }
                
                async function verifyHarvestStillActive() {
                    // Check multiple indicators that harvest is still running
                    const indicators = [
                        () => document.querySelector('[mattooltip="Cancel"]'),
                        () => document.querySelectorAll('mat-progress-bar:not([value="0"])').length > 0,
                        () => document.querySelector('.harvest-active, .processing'),
                        () => !document.querySelector('[mattooltip="Start harvesting"]:not([disabled])')
                    ];
                    
                    let activeCount = 0;
                    for (const indicator of indicators) {
                        if (indicator()) activeCount++;
                    }
                    
                    return activeCount >= 2; // At least 2 indicators should be true
                }
                
                // Enhanced freeze detection with defensive monitoring
                async function monitorHarvestProgressDefensive() {
                    console.log("Starting defensive harvest progress monitoring...");
                    let consecutiveNoProgressCounts = 0;
                    let lastValidProgress = null;
                    let progressStuckWarnings = 0;
                    let totalMonitoringTime = 0;
                    
                    while (totalMonitoringTime < maxHarvestWait) {
                        try {
                            // Check for completion dialog first
                            let dialog = document.querySelector('[role="dialog"]') ||
                                document.querySelector('.mat-dialog-container');
                            if (dialog) {
                                let closeBtn = Array.from(dialog.querySelectorAll('button')).find(btn =>
                                    btn.textContent.trim().toLowerCase() === 'close');
                                if (closeBtn) {
                                    console.log("Harvest completion dialog detected");
                                    return { success: true, dialog: dialog };
                                }
                            }
                            
                            // Multiple progress detection strategies
                            const progressInfo = await detectProgressMultiStrategy();
                            
                            if (progressInfo.percentage !== null) {
                                if (lastValidProgress !== null && 
                                    progressInfo.percentage === lastValidProgress.percentage) {
                                    consecutiveNoProgressCounts++;
                                    console.log(`Progress stuck at ${progressInfo.percentage}% (${consecutiveNoProgressCounts}/${maxNoProgressChecks} checks)`);
                                    
                                    if (consecutiveNoProgressCounts >= maxNoProgressChecks) {
                                        // Additional verification before declaring freeze
                                        const stillActive = await verifyHarvestStillActive();
                                        if (stillActive && progressStuckWarnings < 2) {
                                            progressStuckWarnings++;
                                            consecutiveNoProgressCounts = 0; // Give it another chance
                                            console.log(`Progress appears stuck but harvest is active, continuing... (warning ${progressStuckWarnings}/2)`);
                                        } else {
                                            console.log(`FREEZE CONFIRMED: Progress stuck at ${progressInfo.percentage}% with insufficient activity indicators`);
                                            return { success: false, reason: `Progress frozen at ${progressInfo.percentage}%` };
                                        }
                                    }
                                } else {
                                    consecutiveNoProgressCounts = 0;
                                    progressStuckWarnings = 0;
                                    if (progressInfo.percentage !== (lastValidProgress?.percentage || -1)) {
                                        console.log(`Progress update: ${progressInfo.percentage}% (source: ${progressInfo.source})`);
                                    }
                                    lastValidProgress = progressInfo;
                                }
                            } else {
                                // No progress percentage found
                                const stillActive = await verifyHarvestStillActive();
                                if (!stillActive) {
                                    console.log("No progress indicators and no active harvest detected");
                                    return { success: false, reason: "Harvest stopped - no activity indicators" };
                                }
                            }
                            
                        } catch (error) {
                            console.log(`Progress monitoring error: ${error.message}`);
                            // Continue monitoring even if one check fails
                        }
                        
                        await sleep(progressCheckInterval);
                        totalMonitoringTime += progressCheckInterval;
                    }
                    
                    console.log("Progress monitoring timed out");
                    return { success: false, reason: "Monitoring timeout" };
                }
                
                // Enhanced cancel function with multiple strategies
                async function attemptCancel() {
                    console.log("Attempting to cancel harvest with multiple strategies...");
                    
                    // Strategy 1: Use harvest button as cancel
                    let harvestBtn = document.querySelector('[mattooltip="Start harvesting"]') ||
                        Array.from(document.querySelectorAll('button')).find(btn => {
                            let tooltip = btn.getAttribute('mattooltip');
                            let text = btn.textContent.toLowerCase();
                            return (tooltip && tooltip.toLowerCase().includes('start')) ||
                                   (text.includes('start') && text.includes('harvest'));
                        });
                    
                    if (harvestBtn && !harvestBtn.disabled) {
                        harvestBtn.click();
                        console.log("Harvest/Cancel button clicked (Strategy 1)");
                        await sleep(3000);
                        
                        // Verify cancellation
                        if (!harvestBtn.disabled) {
                            console.log("Cancellation successful via harvest button");
                            return true;
                        }
                    }
                    
                    // Strategy 2: Look for explicit cancel button
                    let explicitCancel = document.querySelector('[mattooltip="Cancel"]') ||
                        Array.from(document.querySelectorAll('button')).find(btn =>
                            btn.textContent.toLowerCase().includes('cancel'));
                    
                    if (explicitCancel && !explicitCancel.disabled) {
                        explicitCancel.click();
                        console.log("Explicit cancel button clicked (Strategy 2)");
                        await sleep(3000);
                        return true;
                    }
                    
                    // Strategy 3: Look for stop/abort buttons
                    let stopBtn = Array.from(document.querySelectorAll('button')).find(btn =>
                        btn.textContent.toLowerCase().includes('stop') ||
                        btn.textContent.toLowerCase().includes('abort')
                    );
                    
                    if (stopBtn && !stopBtn.disabled) {
                        stopBtn.click();
                        console.log("Stop/Abort button clicked (Strategy 3)");
                        await sleep(3000);
                        return true;
                    }
                    
                    console.log("No cancel mechanism found or all strategies failed");
                    return false;
                }
                
                async function automateHarvest() {
                    console.log(`Starting enhanced automated Pegasus harvest sequence with mode: ${currentMode}`);
                    let maxRetries = 3;
                    let retryCount = 0;
                    
                    while (retryCount < maxRetries) {
                        if (retryCount > 0) {
                            console.log(`\nRetry attempt ${retryCount} of ${maxRetries - 1} for mode: ${currentMode}`);
                            await sleep(retryDelay);
                        }
                        
                        try {
                            // Verify UI state before starting
                            await verifyUIState();
                            
                            // Step 1: Select harvest mode
                            console.log(`1. Setting harvest mode to: ${currentMode}`);
                            
                            if (currentMode === 'all') {
                                let allBtn = document.querySelector(ALL_BTN);
                                if (allBtn && !allBtn.disabled) {
                                    allBtn.click();
                                    console.log("'All' button clicked successfully");
                                } else {
                                    throw new Error("'All' button not found or disabled");
                                }
                            } else if (currentMode === 'since last') {
                                let sinceLastBtn = document.querySelector(SINCE_LAST_BTN);
                                if (sinceLastBtn && !sinceLastBtn.disabled) {
                                    sinceLastBtn.click();
                                    console.log("'Since Last' button clicked successfully");
                                } else {
                                    throw new Error("'Since Last' button not found or disabled");
                                }
                            } else if (currentMode === 'date range') {
                                let dateRangeBtn = document.querySelector(DATE_RANGE_BTN);
                                if (dateRangeBtn && !dateRangeBtn.disabled) {
                                    dateRangeBtn.click();
                                    console.log("'Date Range' button clicked successfully");
                                    
                                    await sleep(delayAllClick);
                                    
                                    // Enhanced date field handling
                                    console.log("1.5. Setting date range fields with enhanced detection...");
                                    const [fromInput, toInput] = await findDateInputs();
                                    
                                    if (fromInput && toInput) {
                                        // Set from date
                                        fromInput.focus();
                                        fromInput.value = '';
                                        fromInput.value = fromDate;
                                        fromInput.dispatchEvent(new Event('input', { bubbles: true }));
                                        fromInput.dispatchEvent(new Event('change', { bubbles: true }));
                                        fromInput.dispatchEvent(new Event('blur', { bubbles: true }));
                                        
                                        await sleep(300);
                                        
                                        // Set to date
                                        toInput.focus();
                                        toInput.value = '';
                                        toInput.value = toDate;
                                        toInput.dispatchEvent(new Event('input', { bubbles: true }));
                                        toInput.dispatchEvent(new Event('change', { bubbles: true }));
                                        toInput.dispatchEvent(new Event('blur', { bubbles: true }));
                                        
                                        console.log(`Date range set: ${fromDate} to ${toDate}`);
                                        
                                        // Verify dates were set correctly
                                        await sleep(500);
                                        if (fromInput.value !== fromDate || toInput.value !== toDate) {
                                            console.warn(`Date verification warning: From="${fromInput.value}", To="${toInput.value}"`);
                                        }
                                    } else {
                                        throw new Error("Could not find date input fields with any strategy");
                                    }
                                } else {
                                    throw new Error("'Date Range' button not found or disabled");
                                }
                            }
                            
                            await sleep(delayAllClick);
                            
                            // Step 2: Open Archive Configuration
                            console.log("2. Opening Archive Configuration...");
                            let configBtn = Array.from(document.querySelectorAll('button')).find(btn =>
                                btn.textContent.trim().toLowerCase().includes('configuration') ||
                                (btn.getAttribute('mattooltip') && btn.getAttribute('mattooltip').toLowerCase().includes('configuration'))
                            );
                            
                            if (configBtn) {
                                configBtn.click();
                                console.log("Archive Configuration button clicked");
                            } else {
                                throw new Error("Could not find Archive Configuration button");
                            }
                            
                            await sleep(delayOpenConfig);
                            
                            // Step 3: Set Output Directory
                            console.log(`3. Setting output directory: "${harvestDir}"...`);
                            if (!await setOutputDirectory(harvestDir)) {
                                console.warn("Output directory setting may have failed, but continuing...");
                            }
                            
                            await sleep(delaySetOutputDir);
                            
                            // Step 4: Save configuration
                            console.log("4. Saving Archive Configuration...");
                            if (!clickButtonByText('Save')) {
                                throw new Error("Could not find or click Save button");
                            }
                            
                            await sleep(delaySaveConfig);
                            
                            // Step 5: Start Harvest
                            console.log("5. Clicking Start Harvest...");
                            let harvestBtn = document.querySelector('[mattooltip="Start harvesting"]') ||
                                Array.from(document.querySelectorAll('button')).find(btn => {
                                    let tooltip = btn.getAttribute('mattooltip');
                                    return tooltip && tooltip.toLowerCase().includes('start');
                                });
                            
                            if (harvestBtn && !harvestBtn.disabled) {
                                harvestBtn.click();
                                console.log("'Start Harvesting' button clicked successfully");
                            } else {
                                throw new Error("'Start Harvesting' button not found or disabled");
                            }
                            
                            await sleep(delayHarvestClick);
                            
                            // Step 6: Enhanced progress monitoring with timeout
                            console.log("6. Starting enhanced harvest monitoring...");
                            const progressTimeout = setTimeout(async () => {
                                console.log("Maximum harvest time reached, attempting to cancel...");
                                await attemptCancel();
                            }, maxHarvestWait);
                            
                            const progressResult = await Promise.race([
                                monitorHarvestProgressDefensive(),
                                new Promise((resolve) => {
                                    setTimeout(() => resolve({ success: false, reason: "Global timeout" }), maxHarvestWait + 5000);
                                })
                            ]);
                            
                            clearTimeout(progressTimeout);
                            
                            if (progressResult.success) {
                                console.log("Harvest completed successfully!");
                                
                                // Step 7: Close Summary Dialog
                                console.log("7. Closing harvest summary dialog...");
                                let closeBtn = Array.from(progressResult.dialog.querySelectorAll('button')).find(btn =>
                                    btn.textContent.trim().toLowerCase() === 'close');
                                
                                if (closeBtn && !closeBtn.disabled) {
                                    closeBtn.click();
                                    console.log("Summary dialog closed successfully");
                                    return {
                                        success: true,
                                        message: `Enhanced automated harvest sequence completed successfully with mode: ${currentMode} (attempt ${retryCount + 1})!`
                                    };
                                } else {
                                    throw new Error("Could not close summary dialog");
                                }
                            } else {
                                console.log(`Harvest failed: ${progressResult.reason}`);
                                await attemptCancel(); // Cancel stuck harvest
                                throw new Error(`Harvest failed: ${progressResult.reason}`);
                            }
                            
                        } catch (error) {
                            console.log(`Attempt ${retryCount + 1} failed with mode '${currentMode}': ${error.message}`);
                            
                            // Enhanced cleanup attempt
                            await attemptCancel();
                            await sleep(1000);
                            
                            retryCount++;
                            
                            if (retryCount < maxRetries) {
                                console.log(`Waiting ${retryDelay}ms before retry...`);
                            }
                        }
                    }
                    
                    return { success: false, error: `Failed to complete harvest with mode '${currentMode}' after ${maxRetries} attempts` };
                }
                
                // Execute the enhanced automation
                return await automateHarvest();
                
            }, {
                delayAllClick,
                delayOpenConfig,
                delaySetOutputDir,
                delaySaveConfig,
                delayHarvestClick,
                delayHarvestDialogWait,
                maxHarvestWait,
                retryDelay,
                progressCheckInterval,
                maxNoProgressChecks,
                harvestDir,
                fromDate,
                toDate,
                currentMode,
                ALL_BTN,
                SINCE_LAST_BTN,
                DATE_RANGE_BTN,
                FROM_DATE_INPUT,
                TO_DATE_INPUT,
                START_HARVEST_BTN
            });
            
            // Handle automation result with enhanced logging
            const attemptDuration = Date.now() - attemptStartTime;
            
            if (result.success) {
                logWithTimestamp(`Harvest completed with mode '${currentMode}' in ${attemptDuration}ms. Checking for data...`);
                
                // Wait a moment for files to be written
                await new Promise(resolve => setTimeout(resolve, 3000));
                
                // Check if data was actually harvested
                if (checkForHarvestedData(harvestDir)) {
                    logWithTimestamp(`SUCCESS: Data found in harvest directory with mode '${currentMode}'`);
                    logger.logAttempt(currentMode, attemptNumber, 'SUCCESS', attemptDuration);
                    harvestSucceeded = true;
                    break;
                } else {
                    logWithTimestamp(`WARNING: No data found with mode '${currentMode}' after ${attemptNumber} attempts, trying next mode...`);
                    logger.logAttempt(currentMode, attemptNumber, 'NO_DATA', attemptDuration);
                }
            } else {
                logWithTimestamp(`ERROR: Harvest failed with mode '${currentMode}': ${result.error}`);
                logger.logAttempt(currentMode, attemptNumber, 'FAILED', attemptDuration);
                
                // Enhanced resource monitoring after failure
                await monitorSystemResources();
                
                // Wait before next attempt
                await new Promise(resolve => setTimeout(resolve, retryDelay));
            }
        }
        
        if (harvestSucceeded) {
            exitWithSuccess(`Enhanced Pegasus harvest completed successfully after ${attemptNumber} attempts`);
        } else {
            exitWithError(`All harvest attempts failed. No data collected after trying all modes with enhanced monitoring.`);
        }
        
    } catch (error) {
        logWithTimestamp(`CRITICAL ERROR: ${error.message}`);
        logWithTimestamp(`Stack trace: ${error.stack}`);
        exitWithError(`Enhanced Puppeteer automation failed: ${error.message}`);
    } finally {
        if (browser) {
            try {
                await browser.disconnect();
                logWithTimestamp("Disconnected from browser");
            } catch (error) {
                logWithTimestamp(`Warning: Error disconnecting from browser: ${error.message}`);
            }
        }
    }
})();