// Copyright (c) 2020, Salesforce.org. All rights reserved.
// Use of this source code is governed by a BSD 3-Clause.
// License can be found found in the LICENSE file in this repository.
// Created by Matthew Hubert on 8/14/2020

public class SummitEventsRegistration {
    public static void run(List<SObject> newlist, List<SObject> oldlist) {

        Map<Id, Id> affectedIds = new Map<Id, Id>();
        Map<Id, Id> affectedContactIds = new Map<Id, Id>();
        List<Summit_Events_Registration__c> affectedRegs = new List<Summit_Events_Registration__c>();

        String namespace = SummitEventsNamespace.getNamespace();
        if (String.isNotBlank(namespace)) {
            namespace = namespace.toLowerCase() + '__';
        }

        //Tags that need a little TLC to turn them into real links
        List<String> emailTags = new List<String>{
                'UG_Parking_Pass_Link__c',
                'Add_To_Calendar_Link__c',
                'Event_Registration_Cancel_Link__c',
                'Add_to_Apple_Calendar__c',
                'Add_To_Google_Calendar_Link__c',
                'Add_to_Outlook_Calendar__c',
                'Add_To_Outlook_Web_Calendar__c',
                'Add_To_Yahoo_Calendar__c'
        };

        //Add the namespace to the email tags so that both namespaced and non-namespaced version work
        if (String.isNotBlank(namespace)) {
            List<String> emailTagsPackaged = new List<String>();
            for (String tag : emailTags) {
                emailTagsPackaged.add(namespace + tag);
            }
            emailTags.addAll(emailTagsPackaged);
        }

        //Delineator of content in the email templase
        String originalTemplate = '[[DONT_DELETE_CONTENT_HERE]]';

        Map<Id, Summit_Events_Registration__c> oldListMap = new Map<Id, Summit_Events_Registration__c>();
        if (oldlist != null) {
            for (Summit_Events_Registration__c ol : (List<Summit_Events_Registration__c>) oldlist) {
                oldListMap.put(ol.Id, ol);
            }
        }

        for (Summit_Events_Registration__c r : (List<Summit_Events_Registration__c>) newlist) {

            //Get old Summit_Events_Registration__c by current ID
            Summit_Events_Registration__c oldReg = new Summit_Events_Registration__c(Status__c = 'new', Substatus__c = 'new');
            if (oldListMap.size() > 0) {
                if (r.Id != null) {
                    oldReg = oldListMap.get(r.Id);
                }
            }

            //Get all new trigger Summit_Events_Registration__c that have a status change by comparing old map
            if (String.isNotBlank(r.Registrant_Email__c) && r.Guest_Host_Status__c != 'Hosted registrant') {
                if (String.isNotBlank(oldReg.Id)) {
                    if (r.Status__c != oldReg.Status__c || r.Substatus__c != oldReg.Substatus__c) {
                        affectedIds.put(r.Event__c, r.Event__c);
                        affectedRegs.add(r);
                        if (r.Status__c == 'Confirmed' && r.Substatus__c == 'Attended') {
                            affectedContactIds.put(r.Id, r.Id);
                        }
                    }
                } else {
                    affectedIds.put(r.Event__c, r.Event__c);
                    affectedRegs.add(r);
                    if (r.Status__c == 'Confirmed' && r.Substatus__c == 'Attended') {
                        affectedContactIds.put(r.Id, r.Id);
                    }
                }
            }
        }

        //Get any templates for events that have restistration status changes
        List<Summit_Events_Email__c> matchEmail = [
                SELECT Action_Status__c, Action_Sub_status__c, Event__c, Letterhead_HTML__c, Email_Subject__c,
                        Email_Content__c, Letterhead_Id__c, Org_Email_Id__c, BCC_Email__c
                FROM Summit_Events_Email__c
                WHERE Event__r.Id IN :affectedIds.values()
                AND Action_Status__c != NULL
                AND Action_Status__c != '--Inactive--'
        ];

        List<Task> activityUpdates = new List<Task>();

        //loop through affected event registrations - have status change from old
        for (Summit_Events_Registration__c areg : affectedRegs) {
            //Loop through gather email templates to get template and use registration fields to fill in hooks
            for (Summit_Events_Email__c em : matchEmail) {
                Boolean statusMatch = false;
                Boolean bccRegStatusMatch = false;
                List<String> BCCsToGo = new List<String>();
                if (em.Event__c.equals(areg.Event__c)) {

                    statusMatch = false;

                    if (String.isNotBlank(em.Action_Sub_status__c) && String.isNotBlank(areg.Substatus__c)) {
                        if (em.Action_Sub_status__c.equals(areg.Substatus__c) && em.Action_Status__c.equalsIgnoreCase(areg.Status__c)) {
                            statusMatch = true;
                        }
                    } else if (em.Action_Status__c.equals(areg.Status__c) && String.isBlank(em.Action_Sub_status__c) && String.isBlank(areg.Substatus__c)) {
                        statusMatch = true;
                        if (String.isNotBlank(areg.BCC_Transactional_Email_Statuses__c)) {
                            if (areg.BCC_Transactional_Email_Statuses__c.contains(em.Action_Status__c)) {
                                bccRegStatusMatch = true;
                            }
                        }
                    }

                    //Build the BCC list. No duplicate emails. Split strings.
                    BCCsToGo = addToEmailList(em.BCC_Email__c, BCCsToGo);
                    BCCsToGo = addToEmailList(areg.Registrant_Other_Email__c, BCCsToGo);
                    BCCsToGo = addToEmailList(areg.Registrant_Parent_Email__c, BCCsToGo);
                    if (bccRegStatusMatch) {
                        BCCsToGo = addToEmailList(areg.BCC_Transactional_Emails__c, BCCsToGo);
                    }

                    if (statusMatch) {
                        //Get email template
                        String emailContent = em.Email_Content__c;
                        if (!String.isBlank(em.Letterhead_HTML__c)) {
                            originalTemplate = em.Letterhead_HTML__c;
                        }

                        emailContent = emailContent.replace('$', '\\$');
                        //Regex to find all Apex delineators {! }
                        Pattern TAG_REGEX = Pattern.compile('\\{!(.+?)\\}');
                        Matcher matcher = TAG_REGEX.matcher(emailContent);
                        Map<String, String> foundTags = new Map<String, String>();

                        //loop through found hocks and add only unique
                        while (matcher.find()) {
                            foundTags.put(matcher.group(1), matcher.group(1));
                        }

                        for (String ft : foundTags.values()) {
                            //add only found hooks and recreate regex with more percise
                            Pattern TAG_REGEX2 = Pattern.compile('\\{!(' + ft + ')\\}');
                            Matcher matcher2 = TAG_REGEX2.matcher(emailContent);
                            while (matcher2.find()) {

                                //Get the value for hook from registration have to remove any registration object names since we are already in the object
                                String found = matcher2.group(1).replace(namespace + 'Summit_Events_Registration__c.', '');
                                try {
                                    found = String.valueOf(areg.get(found));
                                } catch (Exception e) {
                                    found = '';
                                }

                                //replaceAll doesn't like nulls
                                if (String.isBlank(found)) {
                                    found = '';
                                }
                                //replace all hooks with found values from regstration

                                if (emailTags.contains(matcher2.group(1))) {
                                    found = found.replace('_HL_ENCODED_', '<a href="');
                                    found = found.replace('_HL__blank_HL_', '</a>');
                                    found = found.replace('_HL_', ' target="_blank">');
                                    found = found.replace(' target=', '');
                                }

                                emailContent = matcher2.replaceAll(found);
                            }
                        }

                        //put email content (after hooks have been replaced with values) into the email template
                        originalTemplate = originalTemplate.replaceAll('\\[\\[DONT_DELETE_CONTENT_HERE\\]\\]', emailContent);

                        //send the message
                        String emailMessage = sendEmail2(areg.Registrant_Email__c, originalTemplate, emailContent, em.Email_Subject__c, em.Org_Email_Id__c, BCCsToGo);

                        //Create an activity task
                        Task nt = new Task();
                        nt.WhatId = areg.Id;
                        nt.WhoId = areg.Contact__c;
                        nt.Type = 'Email';
                        nt.ActivityDate = Date.today();
                        nt.Subject = 'Event status email: ' + em.Action_Status__c + ' - ' + em.Email_Subject__c;
                        nt.Status = 'Completed';
                        nt.Priority = 'Low';

                        nt.Description = emailContent.replaceAll('</p>', '\n'); // Replaces </p> (the paragraph closing tag) with a line break, since it is functionally identical to a line break
                        nt.Description = nt.Description.replaceAll('<(.*?)>', ''); // Replaces angled brackets and everything between with an empty string
                        nt.Description += '\n\n' + 'Registrant Email: ' + areg.Registrant_Email__c;
                        nt.Description = emailMessage + '\n\n' + nt.Description;

                        activityUpdates.add(nt);
                    }

                }
            }
        }

        if (activityUpdates.size() > 0) {
            doCRUD crudToDo = new doCRUD();
            crudToDo.savTask(activityUpdates);
        }
    }

    /*
    This method makes sure no duplicate emails make it into our lists causing BCC failures.
    emailList is the list you want to maintain and emailIn is the new emails you want to add.
     */
    public static List<String> addToEmailList(String emailsInString, List<String> emailList) {
        if (String.isNotBlank(emailsInString)) {
            List<String> emailsIn = splitEmails(emailsInString);
            for (String email : emailsIn) {
                if (!emailList.contains(email)) {
                    emailList.add(email);
                }
            }
        }
        return emailList;
    }

    public static List<String> splitEmails(String emailDelineatedString) {
        List<String> checkedEmails = new List<String>();
        if (String.isNotBlank(emailDelineatedString)) {
            emailDelineatedString = emailDelineatedString.replaceAll('\\s+', ',');
            emailDelineatedString = emailDelineatedString.replaceAll(';', ',');
            List<String> emailList = emailDelineatedString.split(',');
            for (String em : emailList) {
                if (validateEmail(em)) {
                    checkedEmails.add(em);
                }
            }
        }
        return checkedEmails;
    }

    public static Boolean validateEmail(String email) {
        Boolean res = false;
        if (String.isNotBlank(email)) {
            // source: http://www.regular-expressions.info/email.html
            String emailRegex = '^[a-zA-Z0-9._|\\\\%#~`=?&/$^*!}{+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,4}$';
            Pattern MyPattern = Pattern.compile(emailRegex);
            Matcher MyMatcher = MyPattern.matcher(email);
            if (MyMatcher.matches()) {
                res = true;
            }
        }
        return res;
    }

    public static String sendEmail2(String EmailTo, String HTMLBody, String plainBody, String Subject, Id OrgEmailId, List<String> BccList) {
        String emailMessage = 'Email successfully sent!';
        try {
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new String[]{
                    EmailTo
            });
            mail.setSubject(Subject);
            mail.setBccAddresses(BccList);
            mail.setPlainTextBody(plainBody);
            if (String.isBlank(HTMLBody)) {
                mail.setHtmlBody(plainBody);
            } else {
                mail.setHtmlBody(HTMLBody);
            }
            mail.setOrgWideEmailAddressId(OrgEmailId);
            Messaging.SendEmailResult [] r = Messaging.sendEmail(new Messaging.SingleEmailMessage[]{
                    mail
            });
        } catch (Exception ex) {
            emailMessage = 'Email failed with this error: ' + ex.getMessage();
            System.debug(ex.getMessage());
        }
        return emailMessage;
    }

    private without sharing class doCRUD {

        public void savTask(List<Task> taskToSave) {
            try {
                insert taskToSave;
            } catch (Exception e) {
                System.debug(e.getMessage());
            }
        }
    }
}