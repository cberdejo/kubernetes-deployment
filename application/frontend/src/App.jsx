import { useState, useEffect } from 'react';
import toast, { Toaster } from 'react-hot-toast';
import './App.css';

const API_URL = import.meta.env.VITE_API_URL;

function App() {
  const [notes, setNotes] = useState([]);
  const [formData, setFormData] = useState({ name: '', content: '' });
  const [isEditing, setIsEditing] = useState(false);

  const fetchNotes = async () => {
    try {
      const response = await fetch(API_URL);
      const data = await response.json().catch(() => null);

      if (!response.ok) {
        const message =
          (data && (data.error || data.message)) ||
          'Failed to load notes.';
        throw new Error(message);
      }

      setNotes(Array.isArray(data) ? data : []);
    } catch (error) {
      console.error('Error loading notes:', error);
      toast.error(error.message || 'Failed to load notes.');
    }
  };

  useEffect(() => {
    fetchNotes();
  }, []);

  const handleChange = (e) => {
    setFormData({ ...formData, [e.target.name]: e.target.value });
  };

  const handleSubmit = async (e) => {
    e.preventDefault();

    try {
      const isUpdate = isEditing;
      const endpoint = isUpdate ? `${API_URL}/${formData.name}` : API_URL;
      const method = isUpdate ? 'PUT' : 'POST';

      const response = await fetch(endpoint, {
        method,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(formData),
      });

      const data = await response.json().catch(() => null);

      if (!response.ok) {
        const message =
          (data && (data.error || data.message)) ||
          (isUpdate
            ? 'Failed to update the note.'
            : 'Failed to create the note.');
        throw new Error(message);
      }

      toast.success(
        isUpdate ? 'Note updated successfully.' : 'Note created successfully.'
      );

      setIsEditing(false);
      setFormData({ name: '', content: '' });
      fetchNotes();
    } catch (error) {
      console.error('Error saving note:', error);
      toast.error(
        error.message ||
          (isEditing
            ? 'Failed to update the note.'
            : 'Failed to create the note.')
      );
    }
  };

  const handleDelete = async (name) => {
    if (
      !window.confirm(
        `Are you sure you want to delete the note "${name}"?`
      )
    )
      return;

    try {
      const response = await fetch(`${API_URL}/${name}`, { method: 'DELETE' });
      const data = await response.json().catch(() => null);

      if (!response.ok) {
        const message =
          (data && (data.error || data.message)) ||
          'Failed to delete the note.';
        throw new Error(message);
      }

      toast.success('Note deleted successfully.');
      fetchNotes();
    } catch (error) {
      console.error('Error deleting note:', error);
      toast.error(error.message || 'Failed to delete the note.');
    }
  };

  const handleEdit = (note) => {
    setFormData({ name: note.name, content: note.content });
    setIsEditing(true);
    window.scrollTo({ top: 0, behavior: 'smooth' });
  };

  const handleCancel = () => {
    setIsEditing(false);
    setFormData({ name: '', content: '' });
  };

  return (
    <div className="container">
      <Toaster position="top-right" />
      <h1>Notes Manager</h1>

      {/* Form */}
      <form className="note-form" onSubmit={handleSubmit}>
        <h3>
          {isEditing ? `Edit note: ${formData.name}` : 'New note'}
        </h3>

        <input
          type="text"
          name="name"
          placeholder="Unique note name"
          value={formData.name}
          onChange={handleChange}
          required
          disabled={isEditing}
          style={{ backgroundColor: isEditing ? '#e9ecef' : 'white' }}
        />

        <textarea
          name="content"
          placeholder="Write the content here..."
          rows="4"
          value={formData.content}
          onChange={handleChange}
          required
        />

        <div style={{ display: 'flex', gap: '10px' }}>
          <button type="submit">
            {isEditing ? 'Update' : 'Create note'}
          </button>

          {isEditing && (
            <button
              type="button"
              onClick={handleCancel}
              style={{ background: '#6c757d' }}
            >
              Cancel
            </button>
          )}
        </div>
      </form>

      {/* Note List */}
      <div className="notes-grid">
        {notes.length === 0 ? (
          <p style={{ textAlign: 'center', width: '100%' }}>
            There are no notes yet.
          </p>
        ) : (
          notes.map((note) => (
            <div key={note.id} className="note-card">
              <div className="note-header">
                <strong>{note.name}</strong>
                <div>
                  <button
                    className="edit-btn"
                    onClick={() => handleEdit(note)}
                    title="Edit"
                  >
                    ✎
                  </button>
                  <button
                    className="delete-btn"
                    onClick={() => handleDelete(note.name)}
                    title="Delete"
                  >
                    ×
                  </button>
                </div>
              </div>
              <p className="note-content">{note.content}</p>
              <span className="note-date">
                {new Date(note.createdAt).toLocaleString()}
              </span>
            </div>
          ))
        )}
      </div>
    </div>
  );
}

export default App;