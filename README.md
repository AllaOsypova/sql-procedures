# SQL Procedures for IMS and Distribution

This repository contains SQL Server stored procedures used in retail analytics and IMS (Inventory Management System) calculation logic.

## 🧩 Stored Procedures

### 1. sp_Update_CalcIMS.sql
Snapshots monthly stock and shipments. Recalculates sales amounts using pricing logic and adjusts for IMS reporting.

### 2. sp_Update_FactDistributionIMS.sql
Recalculates IMS distribution for a given outlet and date. Handles MSL plans, matrix logic, and group replacements. Updates support tables for OLAP automation.

## 🔧 Usage Example

```sql
EXEC HH.Update_CalcIMS @DateID = 20240501;
EXEC HH.Update_FactDistributionIMS @OL_ID = 1002000414, @DateID = 20240501;
```

Author: Alla Osypova  
Updated: June 15, 2025
