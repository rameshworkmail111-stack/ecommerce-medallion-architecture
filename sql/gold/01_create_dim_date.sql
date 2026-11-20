-- Step 1: Inspect existing project tables

SELECT
    TABLE_SCHEMA,
    TABLE_NAME,
    TABLE_ROWS
FROM information_schema.TABLES
WHERE TABLE_SCHEMA IN ('bronze', 'silver', 'gold')
ORDER BY
    TABLE_SCHEMA,
    TABLE_NAME;
    
-- Step 2: Exact record count validation

SELECT 'bronze.ecommerce_raw' AS Table_Name,
       COUNT(*) AS Actual_Records
FROM bronze.ecommerce_raw

UNION ALL

SELECT 'silver.ecommerce_cleaned',
       COUNT(*)
FROM silver.ecommerce_cleaned

UNION ALL

SELECT 'silver.ecommerce_deduplicated',
       COUNT(*)
FROM silver.ecommerce_deduplicated

UNION ALL

SELECT 'silver.ecommerce_duplicate_exceptions',
       COUNT(*)
FROM silver.ecommerce_duplicate_exceptions;

-- Step 3: Inspect cleaned Silver table structure

DESCRIBE silver.ecommerce_cleaned;

-- Step 4: Check customer attribute consistency

SELECT
    COUNT(DISTINCT Customer_ID) AS Unique_Customers,
    COUNT(DISTINCT CONCAT(Customer_ID, '|', Customer_Age))
        AS Customer_Age_Combinations,
    COUNT(DISTINCT CONCAT(Customer_ID, '|', Customer_Segment))
        AS Customer_Segment_Combinations,
    COUNT(DISTINCT CONCAT(Customer_ID, '|', City))
        AS Customer_City_Combinations
FROM silver.ecommerce_cleaned;

-- Step 5 – Check product dimension candidates
SELECT
    COUNT(DISTINCT Product_Name) AS Unique_Products,
    COUNT(DISTINCT CONCAT(Product_Name, '|', Category))
        AS Product_Category_Combinations
FROM silver.ecommerce_cleaned;

-- Step 6 – Check geography combinations
SELECT
    COUNT(DISTINCT City) AS Unique_Cities,
    COUNT(DISTINCT Region) AS Unique_Regions,
    COUNT(DISTINCT CONCAT(City, '|', Region))
        AS City_Region_Combinations
FROM silver.ecommerce_cleaned;

-- STEP 7: Identify unique values in remaining categorical attributes
-- PURPOSE: Determine the dimension structure for Gold Star Schema

SELECT
    'Sales_Channel' AS Attribute,
    COUNT(DISTINCT Sales_Channel) AS Unique_Values
FROM silver.ecommerce_cleaned

UNION ALL

SELECT 'Device', COUNT(DISTINCT Device)
FROM silver.ecommerce_cleaned

UNION ALL

SELECT 'Payment_Method', COUNT(DISTINCT Payment_Method)
FROM silver.ecommerce_cleaned

UNION ALL

SELECT 'Marketing_Source', COUNT(DISTINCT Marketing_Source)
FROM silver.ecommerce_cleaned

UNION ALL

SELECT 'Order_Status', COUNT(DISTINCT Order_Status)
FROM silver.ecommerce_cleaned

UNION ALL

SELECT 'Return_Status', COUNT(DISTINCT Return_Status)
FROM silver.ecommerce_cleaned;

-- STEP 8: Validate the grain of the Gold fact table
-- PURPOSE: Confirm that one Order_ID represents one unique order transaction

SELECT
    COUNT(*) AS Total_Records,
    COUNT(DISTINCT Order_ID) AS Unique_Orders,
    COUNT(DISTINCT Customer_ID) AS Unique_Customers,
    COUNT(DISTINCT CONCAT(Product_Name, '|', Category)) AS Unique_Products
FROM silver.ecommerce_cleaned;

-- STEP 9: Check missing dimension-related values
-- PURPOSE: Identify NULL or blank values before creating Gold dimension relationships

SELECT
    SUM(Order_ID IS NULL OR TRIM(Order_ID) = '') AS Missing_Order_ID,
    SUM(Customer_ID IS NULL OR TRIM(Customer_ID) = '') AS Missing_Customer_ID,
    SUM(Product_Name IS NULL OR TRIM(Product_Name) = '') AS Missing_Product,
    SUM(Category IS NULL OR TRIM(Category) = '') AS Missing_Category,
    SUM(Order_Date IS NULL) AS Missing_Order_Date,
    SUM(City IS NULL OR TRIM(City) = '') AS Missing_City,
    SUM(Region IS NULL OR TRIM(Region) = '') AS Missing_Region
FROM silver.ecommerce_cleaned;

-- STEP 10: Identify the order date range
-- PURPOSE: Determine the date range required for the Gold date dimension

SELECT
    MIN(Order_Date) AS First_Order_Date,
    MAX(Order_Date) AS Last_Order_Date,
    COUNT(DISTINCT Order_Date) AS Unique_Order_Dates
FROM silver.ecommerce_cleaned;

-- STEP 11: Create Gold Date Dimension
-- PURPOSE: Store calendar attributes for time-based sales analysis

CREATE TABLE gold.dim_date (
    Date_Key INT PRIMARY KEY,
    Full_Date DATE NOT NULL UNIQUE,
    Day_Number INT NOT NULL,
    Day_Name VARCHAR(15) NOT NULL,
    Month_Number INT NOT NULL,
    Month_Name VARCHAR(15) NOT NULL,
    Quarter_Number INT NOT NULL,
    Quarter_Name VARCHAR(5) NOT NULL,
    Year_Number INT NOT NULL,
    Week_Number INT NOT NULL,
    Is_Weekend BOOLEAN NOT NULL
);

-- STEP 12: Populate Gold Date Dimension
-- PURPOSE: Generate calendar records for the complete 2025 date range

INSERT INTO gold.dim_date (
    Date_Key,
    Full_Date,
    Day_Number,
    Day_Name,
    Month_Number,
    Month_Name,
    Quarter_Number,
    Quarter_Name,
    Year_Number,
    Week_Number,
    Is_Weekend
)
WITH RECURSIVE Date_Range AS (
    SELECT DATE('2025-01-01') AS Calendar_Date

    UNION ALL

    SELECT DATE_ADD(Calendar_Date, INTERVAL 1 DAY)
    FROM Date_Range
    WHERE Calendar_Date < '2025-12-31'
)
SELECT
    DATE_FORMAT(Calendar_Date, '%Y%m%d') + 0,
    Calendar_Date,
    DAY(Calendar_Date),
    DAYNAME(Calendar_Date),
    MONTH(Calendar_Date),
    MONTHNAME(Calendar_Date),
    QUARTER(Calendar_Date),
    CONCAT('Q', QUARTER(Calendar_Date)),
    YEAR(Calendar_Date),
    WEEK(Calendar_Date, 3),
    CASE
        WHEN DAYOFWEEK(Calendar_Date) IN (1, 7) THEN TRUE
        ELSE FALSE
    END
FROM Date_Range;

-- STEP 13: Validate Gold Date Dimension
-- PURPOSE: Verify date records, date range, and uniqueness

SELECT
    COUNT(*) AS Total_Date_Records,
    COUNT(DISTINCT Full_Date) AS Unique_Dates,
    MIN(Full_Date) AS First_Date,
    MAX(Full_Date) AS Last_Date,
    SUM(Is_Weekend) AS Weekend_Days
FROM gold.dim_date;

-- STEP 14: Create Gold Customer Dimension
-- PURPOSE: Store unique customer identifiers for customer-level analysis

CREATE TABLE gold.dim_customer (
    Customer_Key INT AUTO_INCREMENT PRIMARY KEY,
    Customer_ID VARCHAR(20) NOT NULL UNIQUE
);

-- STEP 15: Populate Gold Customer Dimension
-- PURPOSE: Insert unique customer identifiers from the Silver layer

INSERT INTO gold.dim_customer (Customer_ID)
SELECT DISTINCT Customer_ID
FROM silver.ecommerce_cleaned
ORDER BY Customer_ID;

-- STEP 16: Validate Gold Customer Dimension
-- PURPOSE: Verify customer count, uniqueness, and missing identifiers

SELECT
    COUNT(*) AS Total_Customers,
    COUNT(DISTINCT Customer_ID) AS Unique_Customers,
    SUM(Customer_ID IS NULL) AS Missing_Customer_ID
FROM gold.dim_customer;

-- STEP 17: Create Gold Product Dimension
-- PURPOSE: Store unique product and category combinations

CREATE TABLE gold.dim_product (
    Product_Key INT AUTO_INCREMENT PRIMARY KEY,
    Product_Name VARCHAR(100) NOT NULL,
    Category VARCHAR(50) NOT NULL,

    CONSTRAINT uq_product_category
        UNIQUE (Product_Name, Category)
);

-- STEP 18: Populate Gold Product Dimension
-- PURPOSE: Insert unique product-category combinations from Silver

INSERT INTO gold.dim_product (
    Product_Name,
    Category
)
SELECT DISTINCT
    Product_Name,
    Category
FROM silver.ecommerce_cleaned
ORDER BY Product_Name, Category;

-- STEP 19: Validate Gold Product Dimension
-- PURPOSE: Verify product records, uniqueness, and missing values

SELECT
    COUNT(*) AS Total_Products,
    COUNT(DISTINCT CONCAT(Product_Name, '|', Category))
        AS Unique_Product_Category_Combinations,
    SUM(Product_Name IS NULL OR TRIM(Product_Name) = '')
        AS Missing_Product_Names,
    SUM(Category IS NULL OR TRIM(Category) = '')
        AS Missing_Categories
FROM gold.dim_product;

-- STEP 20: Create Gold Geography Dimension
-- PURPOSE: Store unique city and region combinations for geographical analysis

CREATE TABLE gold.dim_geography (
    Geography_Key INT AUTO_INCREMENT PRIMARY KEY,
    City VARCHAR(50) NOT NULL,
    Region VARCHAR(50) NOT NULL,

    CONSTRAINT uq_city_region
        UNIQUE (City, Region)
);

-- STEP 21: Populate Gold Geography Dimension
-- PURPOSE: Insert unique city-region combinations from the Silver layer

INSERT INTO gold.dim_geography (
    City,
    Region
)
SELECT DISTINCT
    City,
    Region
FROM silver.ecommerce_cleaned
ORDER BY City, Region;

-- STEP 22: Validate Gold Geography Dimension
-- PURPOSE: Verify city-region combinations, uniqueness, and missing values

SELECT
    COUNT(*) AS Total_Geography_Records,
    COUNT(DISTINCT CONCAT(City, '|', Region))
        AS Unique_City_Region_Combinations,
    SUM(City IS NULL OR TRIM(City) = '') AS Missing_Cities,
    SUM(Region IS NULL OR TRIM(Region) = '') AS Missing_Regions
FROM gold.dim_geography;

-- STEP 23: Create Gold Channel Dimension
-- PURPOSE: Store unique sales-channel and device combinations

CREATE TABLE gold.dim_channel (
    Channel_Key INT AUTO_INCREMENT PRIMARY KEY,
    Sales_Channel VARCHAR(50) NOT NULL,
    Device VARCHAR(50) NOT NULL,

    CONSTRAINT uq_sales_channel_device
        UNIQUE (Sales_Channel, Device)
);

-- STEP 24: Populate Gold Channel Dimension
-- PURPOSE: Insert unique sales-channel and device combinations from Silver

INSERT INTO gold.dim_channel (
    Sales_Channel,
    Device
)
SELECT DISTINCT
    Sales_Channel,
    Device
FROM silver.ecommerce_cleaned
ORDER BY Sales_Channel, Device;

-- STEP 25: Validate Gold Channel Dimension
-- PURPOSE: Verify channel-device combinations, uniqueness, and missing values

SELECT
    COUNT(*) AS Total_Channel_Records,
    COUNT(DISTINCT CONCAT(Sales_Channel, '|', Device))
        AS Unique_Channel_Device_Combinations,
    SUM(Sales_Channel IS NULL OR TRIM(Sales_Channel) = '')
        AS Missing_Sales_Channels,
    SUM(Device IS NULL OR TRIM(Device) = '')
        AS Missing_Devices
FROM gold.dim_channel;

-- STEP 26: Create Gold Payment Dimension
-- PURPOSE: Store unique payment methods for payment analysis

CREATE TABLE gold.dim_payment (
    Payment_Key INT AUTO_INCREMENT PRIMARY KEY,
    Payment_Method VARCHAR(50) NOT NULL UNIQUE
);

-- STEP 27: Populate Gold Payment Dimension
-- PURPOSE: Insert unique payment methods from the Silver layer

INSERT INTO gold.dim_payment (Payment_Method)
SELECT DISTINCT Payment_Method
FROM silver.ecommerce_cleaned
ORDER BY Payment_Method;

-- STEP 28: Validate Gold Payment Dimension
-- PURPOSE: Verify payment method count, uniqueness, and missing values

SELECT
    COUNT(*) AS Total_Payment_Methods,
    COUNT(DISTINCT Payment_Method) AS Unique_Payment_Methods,
    SUM(Payment_Method IS NULL OR TRIM(Payment_Method) = '')
        AS Missing_Payment_Methods
FROM gold.dim_payment;

-- STEP 29: Create Gold Marketing Dimension
-- PURPOSE: Store unique marketing sources for marketing performance analysis

CREATE TABLE gold.dim_marketing (
    Marketing_Key INT AUTO_INCREMENT PRIMARY KEY,
    Marketing_Source VARCHAR(50) NOT NULL UNIQUE
);

-- STEP 30: Populate Gold Marketing Dimension
-- PURPOSE: Insert unique marketing sources from the Silver layer

INSERT INTO gold.dim_marketing (Marketing_Source)
SELECT DISTINCT Marketing_Source
FROM silver.ecommerce_cleaned
ORDER BY Marketing_Source;

-- STEP 31: Validate Gold Marketing Dimension
-- PURPOSE: Verify marketing source count, uniqueness, and missing values

SELECT
    COUNT(*) AS Total_Marketing_Sources,
    COUNT(DISTINCT Marketing_Source) AS Unique_Marketing_Sources,
    SUM(Marketing_Source IS NULL OR TRIM(Marketing_Source) = '')
        AS Missing_Marketing_Sources
FROM gold.dim_marketing;

-- STEP 32: Create Gold Order Status Dimension
-- PURPOSE: Store unique order-status and return-status combinations

CREATE TABLE gold.dim_order_status (
    Order_Status_Key INT AUTO_INCREMENT PRIMARY KEY,
    Order_Status VARCHAR(30) NOT NULL,
    Return_Status VARCHAR(20) NOT NULL,

    CONSTRAINT uq_order_return_status
        UNIQUE (Order_Status, Return_Status)
);

-- STEP 33: Populate Gold Order Status Dimension
-- PURPOSE: Insert unique order-status and return-status combinations from Silver

INSERT INTO gold.dim_order_status (
    Order_Status,
    Return_Status
)
SELECT DISTINCT
    Order_Status,
    Return_Status
FROM silver.ecommerce_cleaned
ORDER BY Order_Status, Return_Status;

-- STEP 34: Validate Gold Order Status Dimension
-- PURPOSE: Verify order-return status combinations, uniqueness, and missing values

SELECT
    COUNT(*) AS Total_Status_Combinations,
    COUNT(DISTINCT CONCAT(Order_Status, '|', Return_Status))
        AS Unique_Status_Combinations,
    SUM(Order_Status IS NULL OR TRIM(Order_Status) = '')
        AS Missing_Order_Status,
    SUM(Return_Status IS NULL OR TRIM(Return_Status) = '')
        AS Missing_Return_Status
FROM gold.dim_order_status;

-- STEP 35: Create Gold Fact Orders Table
-- PURPOSE: Store order-level measures and foreign keys to all dimensions
-- GRAIN: One row per Order_ID

CREATE TABLE gold.fact_orders (

    Order_ID VARCHAR(20) PRIMARY KEY,

    -- Dimension Foreign Keys
    Date_Key INT NOT NULL,
    Customer_Key INT NOT NULL,
    Product_Key INT NOT NULL,
    Geography_Key INT NOT NULL,
    Channel_Key INT NOT NULL,
    Payment_Key INT NOT NULL,
    Marketing_Key INT NOT NULL,
    Order_Status_Key INT NOT NULL,

    -- Customer Snapshot Attributes
    Customer_Age INT,
    Customer_Segment VARCHAR(50),
    Customer_Loyalty_Points INT,

    -- Order Measures
    Quantity INT,
    Unit_Price DECIMAL(12,2),
    Discount_Pct DECIMAL(7,2),
    Gross_Amount DECIMAL(12,2),
    Discount_Amount DECIMAL(12,2),
    Net_Sales DECIMAL(12,2),
    Estimated_Cost DECIMAL(12,2),
    Profit DECIMAL(12,2),
    Profit_Margin_Pct DECIMAL(7,2),

    -- Customer Experience Measures
    Shipping_Days INT,
    Shipping_Data_Status VARCHAR(20),
    Customer_Rating DECIMAL(3,1),
    Delivery_Rating DECIMAL(3,1),
    Customer_Satisfaction DECIMAL(3,1),
    Website_Session_Minutes DECIMAL(7,2),
    Items_Viewed INT,
    Previous_Orders INT,

    -- Foreign Key Constraints
    CONSTRAINT fk_fact_date
        FOREIGN KEY (Date_Key) REFERENCES gold.dim_date(Date_Key),

    CONSTRAINT fk_fact_customer
        FOREIGN KEY (Customer_Key) REFERENCES gold.dim_customer(Customer_Key),

    CONSTRAINT fk_fact_product
        FOREIGN KEY (Product_Key) REFERENCES gold.dim_product(Product_Key),

    CONSTRAINT fk_fact_geography
        FOREIGN KEY (Geography_Key) REFERENCES gold.dim_geography(Geography_Key),

    CONSTRAINT fk_fact_channel
        FOREIGN KEY (Channel_Key) REFERENCES gold.dim_channel(Channel_Key),

    CONSTRAINT fk_fact_payment
        FOREIGN KEY (Payment_Key) REFERENCES gold.dim_payment(Payment_Key),

    CONSTRAINT fk_fact_marketing
        FOREIGN KEY (Marketing_Key) REFERENCES gold.dim_marketing(Marketing_Key),

    CONSTRAINT fk_fact_order_status
        FOREIGN KEY (Order_Status_Key) REFERENCES gold.dim_order_status(Order_Status_Key)

);

-- STEP 36: Populate Gold Fact Orders
-- PURPOSE: Load order-level data and resolve dimension surrogate keys
-- SOURCE: silver.ecommerce_cleaned
-- TARGET: gold.fact_orders
-- GRAIN: One row per Order_ID

INSERT INTO gold.fact_orders (
    Order_ID,
    Date_Key,
    Customer_Key,
    Product_Key,
    Geography_Key,
    Channel_Key,
    Payment_Key,
    Marketing_Key,
    Order_Status_Key,
    Customer_Age,
    Customer_Segment,
    Customer_Loyalty_Points,
    Quantity,
    Unit_Price,
    Discount_Pct,
    Gross_Amount,
    Discount_Amount,
    Net_Sales,
    Estimated_Cost,
    Profit,
    Profit_Margin_Pct,
    Shipping_Days,
    Shipping_Data_Status,
    Customer_Rating,
    Delivery_Rating,
    Customer_Satisfaction,
    Website_Session_Minutes,
    Items_Viewed,
    Previous_Orders
)
SELECT
    s.Order_ID,
    CAST(DATE_FORMAT(s.Order_Date, '%Y%m%d') AS UNSIGNED),
    c.Customer_Key,
    p.Product_Key,
    g.Geography_Key,
    ch.Channel_Key,
    pm.Payment_Key,
    m.Marketing_Key,
    os.Order_Status_Key,
    s.Customer_Age,
    s.Customer_Segment,
    s.Customer_Loyalty_Points,
    s.Quantity,
    s.Unit_Price,
    s.Discount_Pct,
    s.Gross_Amount,
    s.Discount_Amount,
    s.Net_Sales,
    s.Estimated_Cost,
    s.Profit,
    s.Profit_Margin_Pct,
    s.Shipping_Days,
    s.Shipping_Data_Status,
    s.Customer_Rating,
    s.Delivery_Rating,
    s.Customer_Satisfaction,
    s.Website_Session_Minutes,
    s.Items_Viewed,
    s.Previous_Orders

FROM silver.ecommerce_cleaned s

INNER JOIN gold.dim_date d
    ON d.Full_Date = s.Order_Date

INNER JOIN gold.dim_customer c
    ON c.Customer_ID = s.Customer_ID

INNER JOIN gold.dim_product p
    ON p.Product_Name = s.Product_Name
    AND p.Category = s.Category

INNER JOIN gold.dim_geography g
    ON g.City = s.City
    AND g.Region = s.Region

INNER JOIN gold.dim_channel ch
    ON ch.Sales_Channel = s.Sales_Channel
    AND ch.Device = s.Device

INNER JOIN gold.dim_payment pm
    ON pm.Payment_Method = s.Payment_Method

INNER JOIN gold.dim_marketing m
    ON m.Marketing_Source = s.Marketing_Source

INNER JOIN gold.dim_order_status os
    ON os.Order_Status = s.Order_Status
    AND os.Return_Status = s.Return_Status;
    
-- STEP 37: Validate Gold Fact Orders
-- PURPOSE: Verify fact record count, order uniqueness, and date range

SELECT
    COUNT(*) AS Total_Fact_Records,
    COUNT(DISTINCT Order_ID) AS Unique_Orders,
    MIN(Order_ID) AS First_Order_ID,
    MAX(Order_ID) AS Last_Order_ID,
    MIN(Date_Key) AS First_Order_Date_Key,
    MAX(Date_Key) AS Last_Order_Date_Key
FROM gold.fact_orders;

-- STEP 38: Validate Gold Fact Foreign Keys
-- PURPOSE: Check missing dimension keys and foreign-key coverage

SELECT
    COUNT(*) AS Total_Fact_Records,

    SUM(Date_Key IS NULL) AS Missing_Date_Key,
    SUM(Customer_Key IS NULL) AS Missing_Customer_Key,
    SUM(Product_Key IS NULL) AS Missing_Product_Key,
    SUM(Geography_Key IS NULL) AS Missing_Geography_Key,
    SUM(Channel_Key IS NULL) AS Missing_Channel_Key,
    SUM(Payment_Key IS NULL) AS Missing_Payment_Key,
    SUM(Marketing_Key IS NULL) AS Missing_Marketing_Key,
    SUM(Order_Status_Key IS NULL) AS Missing_Order_Status_Key

FROM gold.fact_orders;

-- STEP 39: Reconcile Silver and Gold
-- PURPOSE: Verify that every Silver order exists exactly once in Gold

SELECT
    (SELECT COUNT(*)
     FROM silver.ecommerce_cleaned) AS Silver_Records,

    (SELECT COUNT(*)
     FROM gold.fact_orders) AS Gold_Records,

    (SELECT COUNT(*)
     FROM silver.ecommerce_cleaned s
     LEFT JOIN gold.fact_orders f
        ON s.Order_ID = f.Order_ID
     WHERE f.Order_ID IS NULL) AS Missing_In_Gold,

    (SELECT COUNT(*)
     FROM gold.fact_orders f
     LEFT JOIN silver.ecommerce_cleaned s
        ON f.Order_ID = s.Order_ID
     WHERE s.Order_ID IS NULL) AS Extra_In_Gold;
     
-- STEP 40: Validate Gold Star Schema Relationships
-- PURPOSE: Inspect all foreign-key relationships between Fact and Dimension tables

SELECT
    TABLE_NAME,
    COLUMN_NAME,
    CONSTRAINT_NAME,
    REFERENCED_TABLE_NAME,
    REFERENCED_COLUMN_NAME
FROM information_schema.KEY_COLUMN_USAGE
WHERE TABLE_SCHEMA = 'gold'
  AND REFERENCED_TABLE_NAME IS NOT NULL
ORDER BY TABLE_NAME, COLUMN_NAME;

-- STEP 41: Validate Gold Financial Aggregates
-- PURPOSE: Compare financial totals between Silver and Gold
-- EXPECTATION: Both layers should produce identical totals

SELECT
    'Silver' AS Data_Layer,
    SUM(Gross_Amount) AS Total_Gross_Amount,
    SUM(Discount_Amount) AS Total_Discount_Amount,
    SUM(Net_Sales) AS Total_Net_Sales,
    SUM(Estimated_Cost) AS Total_Estimated_Cost,
    SUM(Profit) AS Total_Profit
FROM silver.ecommerce_cleaned

UNION ALL

SELECT
    'Gold' AS Data_Layer,
    SUM(Gross_Amount),
    SUM(Discount_Amount),
    SUM(Net_Sales),
    SUM(Estimated_Cost),
    SUM(Profit)
FROM gold.fact_orders;

-- STEP 42: Validate Gold Dimension Record Counts
-- PURPOSE: Verify that all dimension tables contain the expected records

SELECT 'dim_date' AS Table_Name, COUNT(*) AS Total_Records
FROM gold.dim_date

UNION ALL

SELECT 'dim_customer', COUNT(*)
FROM gold.dim_customer

UNION ALL

SELECT 'dim_product', COUNT(*)
FROM gold.dim_product

UNION ALL

SELECT 'dim_geography', COUNT(*)
FROM gold.dim_geography

UNION ALL

SELECT 'dim_channel', COUNT(*)
FROM gold.dim_channel

UNION ALL

SELECT 'dim_payment', COUNT(*)
FROM gold.dim_payment

UNION ALL

SELECT 'dim_marketing', COUNT(*)
FROM gold.dim_marketing

UNION ALL

SELECT 'dim_order_status', COUNT(*)
FROM gold.dim_order_status

UNION ALL

SELECT 'fact_orders', COUNT(*)
FROM gold.fact_orders;