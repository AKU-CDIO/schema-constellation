/* Author: test */
USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_PatientInsurance]    Script Date: 2026-08-05 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Stored Procedure : dbo.usp_Build_FCAP1A_PatientInsurance
    Version          : 0.2
    Author           : Derick Imbati
    Development Date : 2026-08-05

    Purpose:
        Builds the FCAP 1A Patient Insurance dataset - visit-level insurance
        records (insurer, policy, subscriber, order/priority and contact
        information) anchored on BarAcct_Insurances, enriched with patient
        keys/demographics, restricted to the Extended FCAP cohort
        -> dbo.tbl_FCAP1A_PatientInsurance

    Keys carried (as per Orders SP):
        SourceID, PatientID, VisitID, EmrNumber,
        MultipleDepartmentMedicalRecordNumber, AccountNumber,
        Name, Birthdate, Age, Sex, SocialSecurityNumber, HealthCareNumber,
        RegistrationStatus, AdmitDateTime, ServiceDateTime

    Notes:
        - Insurance is tied to the visit/account where possible
          (BarAcct_Insurances + BarAcct_InsurancePolicy).
        - Insurance order/priority comes from patient-level
          HimRec_InsuranceOrder (MIN SortOrder per patient + insurance).
        - Execute this script as a single batch. Do not insert GO
          statements inside the procedure body.
*/

CREATE OR ALTER PROCEDURE [dbo].[usp_Build_FCAP1A_PatientInsurance]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunStart        DATETIME = SYSDATETIME();
    DECLARE @RunEnd          DATETIME;
    DECLARE @DurationSeconds INT;
    DECLARE @RecordCount     INT = 0;
    DECLARE @TotalEligible   INT = 0;

    DECLARE @WindowStart      DATE = '2022-11-05';
    DECLARE @WindowEnd        DATE = '2026-06-14';
    DECLARE @WindowEndNextDay DATE = DATEADD(DAY, 1, @WindowEnd);

    -- Source tables involved in this build (used to populate SourceTable column)
    DECLARE @SourceTableList NVARCHAR(500) =
        N'BarAcct_Insurances, BarAcct_InsurancePolicy, HimRec_InsuranceOrder, RegAcct_Main, HimRec_Main, HimSubs_Main, HimSubs_Insurances, MisIns_Main, MisFinClass_Main, MisRelat_Main, MisStateProv_Main, MisCntry_Main, MisEmpStatus_Main, MisEmplr_Main, tbl_FCAP1A_Cohort10_Extended';

    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log','U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log (
            LogID           INT IDENTITY(1,1) PRIMARY KEY,
            RunStart        DATETIME        NOT NULL,
            RunEnd          DATETIME        NULL,
            DurationSeconds INT             NULL,
            RunStatus       VARCHAR(20)     NOT NULL,
            DataTopic       NVARCHAR(100)   NOT NULL,
            WindowStart     DATE            NULL,
            WindowEnd       DATE            NULL,
            TotalEligible   INT             NULL,
            RecordCount     INT             NULL,
            ProcessedBy     NVARCHAR(100)   NOT NULL DEFAULT SYSTEM_USER,
            ErrorMessage    NVARCHAR(4000)  NULL,
            Remarks         NVARCHAR(4000)  NULL
        );
    END;

    IF OBJECT_ID('dbo.tbl_FCAP1A_PatientInsurance','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_PatientInsurance;

    CREATE TABLE dbo.tbl_FCAP1A_PatientInsurance (
        InsuranceRowID                    INT IDENTITY(1,1) NOT NULL PRIMARY KEY,

        SourceID                          NVARCHAR(50)      NULL,
        PatientID                         NVARCHAR(50)      NOT NULL,
        VisitID                           NVARCHAR(50)      NULL,
        EmrNumber                         NVARCHAR(255)     NULL,
        MultipleDepartmentMedicalRecordNumber NVARCHAR(255) NULL,
        AccountNumber                     NVARCHAR(255)     NULL,
        Name                              NVARCHAR(255)     NULL,
        Birthdate                         DATETIME          NULL,
        Age                               NVARCHAR(50)      NULL,
        Sex                               NVARCHAR(50)      NULL,
        SocialSecurityNumber              NVARCHAR(50)      NULL,
        HealthCareNumber                  NVARCHAR(255)     NULL,
        RegistrationStatus                NVARCHAR(255)     NULL,
        AdmitDateTime                     DATETIME          NULL,
        ServiceDateTime                   DATETIME          NULL,

        InsuranceID                       NVARCHAR(255)     NULL,
        InsuranceName                     NVARCHAR(255)     NULL,
        InsuranceMnemonic                 NVARCHAR(255)     NULL,
        InsuranceGroup                    NVARCHAR(255)     NULL,
        FinancialClassID                  NVARCHAR(255)     NULL,
        FinancialClassName                NVARCHAR(255)     NULL,
        InsuranceOrder                    INT               NULL,

        PolicyNumber                      NVARCHAR(255)     NULL,
        CoverageNumber                    NVARCHAR(255)     NULL,
        GroupNumber                       NVARCHAR(255)     NULL,
        GroupName                         NVARCHAR(255)     NULL,
        PolicyEffectiveDate               DATETIME          NULL,
        PolicyExpirationDate              DATETIME          NULL,
        PolicySubNumber                   NVARCHAR(255)     NULL,

        SubscriberID                      NVARCHAR(255)     NULL,
        SubscriberNameLast                NVARCHAR(255)     NULL,
        SubscriberNameFirst               NVARCHAR(255)     NULL,
        SubscriberNameMiddle              NVARCHAR(255)     NULL,
        SubscriberRelationship            NVARCHAR(255)     NULL,
        SubscriberPolicyNumber            NVARCHAR(255)     NULL,
        EmploymentStatus                  NVARCHAR(255)     NULL,
        EmployerName                      NVARCHAR(255)     NULL,
        EmployerLocation                  NVARCHAR(255)     NULL,

        InsuranceOtherName                NVARCHAR(255)     NULL,
        InsuranceAddress1                 NVARCHAR(255)     NULL,
        InsuranceAddress2                 NVARCHAR(255)     NULL,
        InsuranceCity                     NVARCHAR(255)     NULL,
        InsuranceState                    NVARCHAR(255)     NULL,
        InsuranceZip                      NVARCHAR(255)     NULL,
        InsuranceCountry                  NVARCHAR(255)     NULL,
        InsurancePhone                    NVARCHAR(255)     NULL,
        InsuranceEmail                    NVARCHAR(255)     NULL,
        InsuranceExpirationDate           DATETIME          NULL,

        RowUpdateDatetime                 DATETIME          NULL,
        SourceTable                       NVARCHAR(500)     NOT NULL,
        ExecutionOn                       DATETIME          NOT NULL
    );

    BEGIN TRY

        SELECT @TotalEligible = COUNT(*)
        FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        IF OBJECT_ID('tempdb..#Cohort') IS NOT NULL DROP TABLE #Cohort;

        SELECT DISTINCT
            PatientID
        INTO #Cohort
        FROM dbo.tbl_FCAP1A_Cohort10_Extended
        WHERE PatientID IS NOT NULL;

        IF OBJECT_ID('tempdb..#InsuranceDetails') IS NOT NULL DROP TABLE #InsuranceDetails;

        SELECT
            b.SourceID,
            ra.PatientID,
            b.VisitID,
            hm.EmrNumber,
            hm.MultipleDepartmentMedicalRecordNumber,
            ra.AccountNumber,
            CONCAT(hm.NameFirst, ' ', hm.NameMiddle, ' ', hm.NameLast) AS Name,
            hm.Birthdate,
            hm.Age,
            hm.Sex,
            hm.SocialSecurityNumber,
            hm.HealthCareNumber,
            ra.RegistrationStatus,
            ra.AdmitDateTime,
            ra.ServiceDateTime,

            b.Insurance_MisInsID AS InsuranceID,
            mi.Name AS InsuranceName,
            mi.Mnemonic AS InsuranceMnemonic,
            mi.InsuranceGroup_MisInsGroupID AS InsuranceGroup,
            mi.FinancialClass_MisFinClassID AS FinancialClassID,
            fin.Name AS FinancialClassName,
            io.InsuranceOrder,

            pol.InsurancePolicyNumber AS PolicyNumber,
            pol.InsurancePolicyCoverageNumber AS CoverageNumber,
            pol.InsurancePolicyGroupNumber AS GroupNumber,
            emprGroup.Name AS GroupName,
            pol.InsurancePolicyEffectiveDateID AS PolicyEffectiveDate,
            b.InsuranceExpirationDate AS PolicyExpirationDate,
            pol.InsurancePolicySubNumber AS PolicySubNumber,

            sub.HimSubsID AS SubscriberID,
            sub.NameLast AS SubscriberNameLast,
            sub.NameFirst AS SubscriberNameFirst,
            sub.NameMiddle AS SubscriberNameMiddle,
            rel.Name AS SubscriberRelationship,
            si.InsuranceSubscriberPolicyNumber AS SubscriberPolicyNumber,
            emp.Name AS EmploymentStatus,
            empr.Name AS EmployerName,
            pol.InsurancePolicyEmployerLocation AS EmployerLocation,

            b.InsuranceOtherName,
            b.InsuranceAddress1,
            b.InsuranceAddress2,
            b.InsuranceCity,
            st.Name AS InsuranceState,
            b.InsuranceZip,
            cnt.Name AS InsuranceCountry,
            b.InsurancePhone,
            b.InsuranceEmail,
            b.InsuranceExpirationDate,

            COALESCE(pol.RowUpdateDateTime, b.RowUpdateDateTime) AS RowUpdateDatetime
        INTO #InsuranceDetails
        FROM [NBIDRSRV2].[AKULiveATdb].[dbo].BarAcct_Insurances AS b

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].RegAcct_Main AS ra
            ON ra.SourceID = b.SourceID
           AND ra.VisitID  = b.VisitID

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].HimRec_Main AS hm
            ON hm.SourceID  = ra.SourceID
           AND hm.PatientID = ra.PatientID

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].BarAcct_InsurancePolicy AS pol
            ON pol.SourceID       = b.SourceID
           AND pol.VisitID        = b.VisitID
           AND pol.Insurance_MisInsID = b.Insurance_MisInsID

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].MisIns_Main AS mi
            ON mi.SourceID = b.SourceID
           AND mi.MisInsID = b.Insurance_MisInsID

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].MisFinClass_Main AS fin
            ON fin.MisFinClassID = mi.FinancialClass_MisFinClassID

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].MisRelat_Main AS rel
            ON rel.MisRelatID = b.InsurancePatientToSubRelationship_MisRelatID

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].HimSubs_Main AS sub
            ON sub.HimSubsID = b.InsurancePolicySubscriber_HimSubsID

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].HimSubs_Insurances AS si
            ON si.HimSubsID         = sub.HimSubsID
           AND si.Insurance_MisInsID = b.Insurance_MisInsID

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].MisEmpStatus_Main AS emp
            ON emp.MisEmpStatusID = pol.InsurancePolicyEmploymentStatus_MisEmpStatusID

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].MisEmplr_Main AS empr
            ON empr.MisEmplrID = pol.InsurancePolicyEmployerName_MisEmplrID

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].MisEmplr_Main AS emprGroup
            ON emprGroup.MisEmplrID = pol.InsurancePolicyGroupName_MisEmplrID

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].MisStateProv_Main AS st
            ON st.MisStateProvID = b.InsuranceState_MisStateProvID

        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].MisCntry_Main AS cnt
            ON cnt.MisCntryID = b.InsuranceCountry_MisCntryID

        LEFT JOIN
        (
            SELECT
                PatientID,
                SourceID,
                InsuranceOrderInsurance_MisInsID,
                MIN(SortOrder) AS InsuranceOrder
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].HimRec_InsuranceOrder
            WHERE SortOrder IS NOT NULL
            GROUP BY
                PatientID,
                SourceID,
                InsuranceOrderInsurance_MisInsID
        ) AS io
            ON io.SourceID                      = b.SourceID
           AND io.PatientID                     = ra.PatientID
           AND io.InsuranceOrderInsurance_MisInsID = b.Insurance_MisInsID

        WHERE COALESCE(
                pol.InsurancePolicyEffectiveDateID,
                b.InsuranceExpirationDate,
                pol.RowUpdateDateTime,
                b.RowUpdateDateTime
              ) >= @WindowStart
          AND COALESCE(
                pol.InsurancePolicyEffectiveDateID,
                b.InsuranceExpirationDate,
                pol.RowUpdateDateTime,
                b.RowUpdateDateTime
              ) < @WindowEndNextDay;

        INSERT INTO dbo.tbl_FCAP1A_PatientInsurance (
            SourceID,
            PatientID,
            VisitID,
            EmrNumber,
            MultipleDepartmentMedicalRecordNumber,
            AccountNumber,
            Name,
            Birthdate,
            Age,
            Sex,
            SocialSecurityNumber,
            HealthCareNumber,
            RegistrationStatus,
            AdmitDateTime,
            ServiceDateTime,
            InsuranceID,
            InsuranceName,
            InsuranceMnemonic,
            InsuranceGroup,
            FinancialClassID,
            FinancialClassName,
            InsuranceOrder,
            PolicyNumber,
            CoverageNumber,
            GroupNumber,
            GroupName,
            PolicyEffectiveDate,
            PolicyExpirationDate,
            PolicySubNumber,
            SubscriberID,
            SubscriberNameLast,
            SubscriberNameFirst,
            SubscriberNameMiddle,
            SubscriberRelationship,
            SubscriberPolicyNumber,
            EmploymentStatus,
            EmployerName,
            EmployerLocation,
            InsuranceOtherName,
            InsuranceAddress1,
            InsuranceAddress2,
            InsuranceCity,
            InsuranceState,
            InsuranceZip,
            InsuranceCountry,
            InsurancePhone,
            InsuranceEmail,
            InsuranceExpirationDate,
            RowUpdateDatetime,
            SourceTable,
            ExecutionOn
        )
        SELECT
            c.SourceID,
            cohort.PatientID,
            c.VisitID,
            c.EmrNumber,
            c.MultipleDepartmentMedicalRecordNumber,
            c.AccountNumber,
            c.Name,
            c.Birthdate,
            c.Age,
            c.Sex,
            c.SocialSecurityNumber,
            c.HealthCareNumber,
            c.RegistrationStatus,
            c.AdmitDateTime,
            c.ServiceDateTime,
            c.InsuranceID,
            c.InsuranceName,
            c.InsuranceMnemonic,
            c.InsuranceGroup,
            c.FinancialClassID,
            c.FinancialClassName,
            c.InsuranceOrder,
            c.PolicyNumber,
            c.CoverageNumber,
            c.GroupNumber,
            c.GroupName,
            c.PolicyEffectiveDate,
            c.PolicyExpirationDate,
            c.PolicySubNumber,
            c.SubscriberID,
            c.SubscriberNameLast,
            c.SubscriberNameFirst,
            c.SubscriberNameMiddle,
            c.SubscriberRelationship,
            c.SubscriberPolicyNumber,
            c.EmploymentStatus,
            c.EmployerName,
            c.EmployerLocation,
            c.InsuranceOtherName,
            c.InsuranceAddress1,
            c.InsuranceAddress2,
            c.InsuranceCity,
            c.InsuranceState,
            c.InsuranceZip,
            c.InsuranceCountry,
            c.InsurancePhone,
            c.InsuranceEmail,
            c.InsuranceExpirationDate,
            c.RowUpdateDatetime,
            @SourceTableList AS SourceTable,
            @RunStart        AS ExecutionOn
        FROM #Cohort AS cohort
        INNER JOIN #InsuranceDetails AS c
            ON cohort.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
             = c.PatientID     COLLATE SQL_Latin1_General_CP1_CI_AS;

        SELECT @RecordCount = COUNT(*)
        FROM dbo.tbl_FCAP1A_PatientInsurance;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            TotalEligible,
            RecordCount,
            ProcessedBy,
            ErrorMessage,
            Remarks
        )
        VALUES (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'SUCCESS',
            N'PatientInsurance',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            @RecordCount,
            SYSTEM_USER,
            NULL,
            N'Visit-level insurance from BarAcct_Insurances/BarAcct_InsurancePolicy with patient keys/demographics enrichment.'
        );

        PRINT 'PatientInsurance complete. Rows: ' + CAST(@RecordCount AS VARCHAR(20));

    END TRY
    BEGIN CATCH

        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            TotalEligible,
            RecordCount,
            ProcessedBy,
            ErrorMessage,
            Remarks
        )
        VALUES (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'FAILED',
            N'PatientInsurance',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            NULL,
            SYSTEM_USER,
            @Err,
            N'Error during PatientInsurance rebuild.'
        );

        THROW;
    END CATCH
END
GO
