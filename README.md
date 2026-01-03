🩺 PANTRY DOCTOR

Pantry Doctor is an AI-powered clinical nutrition assistant built with Flutter. It helps patients manage their diet based on medical lab reports, detects food purity via forensic scanning, and generates condition-safe recipes.

🚀 Features

Medical Report Analysis: Instantly extracts diagnosis and dietary restrictions from lab images.

3-Meal Prescription: Automatically generates a permanent Morning/Lunch/Evening meal plan tailored to your health profile.

Forensic Lab: Uses Gemini 2.5 Flash to scan food samples for purity and adulterants.

Safety Guard: Real-time AI detection to prevent non-edible items from being processed.

Secure ID Card: Professional patient identity profile.

🛠️ Tech Stack

Framework: Flutter

AI Brain: Google Gemini 2.5 Flash

Backend: Firebase (Auth & Firestore)

Security: Dotenv key encryption

🛡️ Security Note

This project uses .env files to store API keys. Ensure you create a local .env file with GEMINI_API_KEY_1 and GEMINI_API_KEY_2 to run the app.